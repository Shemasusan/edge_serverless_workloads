#include <sw/redis++/redis++.h>
#include <nlohmann/json.hpp>
#include <fftw3.h>
#include <tbb/parallel_for.h>
#include <tbb/blocked_range.h>
#include <tbb/task_arena.h>
#include <tbb/global_control.h>
#include <iostream>
#include <vector>
#include <string>
#include <cmath>
#include <algorithm>
#include <memory>
#include <mutex>
#include <thread>
#include <atomic>
#include "httplib.h"

using json = nlohmann::json;
using namespace sw::redis;

struct Stats {
    double dominant_freq_hz = NAN;
    std::vector<double> spectrum;
    double mean = NAN, std_dev = NAN, min = NAN, max = NAN;
};

// ---------- FFTW plan/cache per thread ----------
static std::mutex fftw_mu;
static std::atomic<bool> fftw_inited{false};

struct FftThreadCtx {
    int N = 0;
    double *in = nullptr;
    fftw_complex *out = nullptr;
    fftw_plan plan = nullptr;
    ~FftThreadCtx() {
        if (plan) fftw_destroy_plan(plan);
        if (in) fftw_free(in);
        if (out) fftw_free(out);
    }
};

static thread_local std::unique_ptr<FftThreadCtx> tl_fft;

static void fftw_global_init(int threads) {
    bool expected=false;
    if (fftw_inited.compare_exchange_strong(expected,true)) {
        std::lock_guard<std::mutex> lk(fftw_mu);
        fftw_init_threads();
        fftw_plan_with_nthreads(std::max(1, threads));
    }
}

static void fft_prepare_plan(int N) {
    if (!tl_fft) tl_fft = std::make_unique<FftThreadCtx>();
    if (tl_fft->N == N && tl_fft->plan) return;
    if (tl_fft->plan) { fftw_destroy_plan(tl_fft->plan); tl_fft->plan=nullptr; }
    if (tl_fft->in) { fftw_free(tl_fft->in); tl_fft->in=nullptr; }
    if (tl_fft->out) { fftw_free(tl_fft->out); tl_fft->out=nullptr; }

    tl_fft->N = N;
    tl_fft->in  = (double*)fftw_malloc(sizeof(double)*N);
    tl_fft->out = (fftw_complex*)fftw_malloc(sizeof(fftw_complex)*(N/2+1));
    {
        std::lock_guard<std::mutex> lk(fftw_mu); // FFTW planning is not thread-safe
        tl_fft->plan = fftw_plan_dft_r2c_1d(N, tl_fft->in, tl_fft->out, FFTW_ESTIMATE);
    }
}

// ---------- Stats/FFT ----------
static Stats compute_stats(const std::vector<json> &messages, const std::string &key) {
    std::vector<double> values, times;
    values.reserve(messages.size()); times.reserve(messages.size());
    for (const auto &m : messages) {
        if (!m.is_object()) continue;
        auto itv = m.find(key);
        auto itt = m.find("timestamp");
        if (itv==m.end() || itt==m.end()) continue;
        try {
            double v = itv->get<double>();
            double t = itt->get<double>();
            if (std::isfinite(v) && std::isfinite(t)) { values.push_back(v); times.push_back(t); }
        } catch (...) { /* skip */ }
    }

    Stats s;
    if (values.size() < 8) return s;

    // sort by time
    std::vector<size_t> idx(values.size());
    for (size_t i=0;i<idx.size();++i) idx[i]=i;
    std::sort(idx.begin(), idx.end(), [&](size_t a, size_t b){ return times[a] < times[b]; });

    size_t N = values.size();
    std::vector<double> t_sorted(N), v_sorted(N);
    for (size_t i=0;i<N;++i){ t_sorted[i]=times[idx[i]]; v_sorted[i]=values[idx[i]]; }

    double t0 = t_sorted.front();
    for (auto &tt: t_sorted) tt -= t0;
    double tmax = std::max(1e-6, t_sorted.back());

    // resample to uniform grid
    std::vector<double> uniform_t(N), v_interp(N);
    for(size_t i=0;i<N;++i) uniform_t[i] = tmax * i / (N-1);

    size_t j=0;
    for (size_t i=0;i<N;++i){
        double tt=uniform_t[i];
        while (j+1<N && t_sorted[j+1] < tt) ++j;
        if (j+1>=N) { v_interp[i]=v_sorted.back(); continue; }
        double t0_=t_sorted[j], t1_=t_sorted[j+1];
        double v0_=v_sorted[j], v1_=v_sorted[j+1];
        double alpha = (t1_>t0_) ? (tt-t0_)/(t1_-t0_) : 0.0;
        v_interp[i] = v0_ + alpha*(v1_-v0_);
    }

    // basic stats
    double sum=0, sumsq=0; double vmin=v_interp[0], vmax=v_interp[0];
    for (double x: v_interp){ sum+=x; sumsq+=x*x; vmin=std::min(vmin,x); vmax=std::max(vmax,x); }
    double mean=sum/N, var=(sumsq/N)-mean*mean; var = std::max(0.0,var);
    double stddev = std::sqrt(var);
    s.mean=mean; s.std_dev=stddev; s.min=vmin; s.max=vmax;

    // normalize
    const double denom = (stddev>1e-12)?stddev:1.0;
    // choose FFT length as next power-of-two for friendlier performance
    size_t M=1; while (M<N) M<<=1; if (M<64) M=64;
    std::vector<double> signal(M,0.0);
    for (size_t i=0;i<std::min(M,N);++i) signal[i]=(v_interp[i]-mean)/denom;

    // FFT
    fft_prepare_plan((int)M);
    for (size_t i=0;i<M;++i) tl_fft->in[i]=signal[i];
    fftw_execute(tl_fft->plan);

    std::vector<double> mags; mags.reserve(M/2+1);
    double dt=(N>1)?(uniform_t[1]-uniform_t[0]):1.0;
    std::vector<double> freqs; freqs.reserve(M/2+1);
    for (size_t k=0;k<=M/2;++k){
        double re = tl_fft->out[k][0], im = tl_fft->out[k][1];
        mags.push_back(std::hypot(re,im));
        freqs.push_back((double)k / (dt * M));
    }

    // skip k=0 DC
    size_t maxidx=1; double maxmag=mags[1];
    for (size_t k=2;k<mags.size();++k){ if (mags[k]>maxmag){ maxmag=mags[k]; maxidx=k; } }
    s.dominant_freq_hz = (mags.size()>1) ? freqs[maxidx] : NAN;

    size_t keep = std::min<size_t>(10, mags.size());
    s.spectrum.assign(mags.begin(), mags.begin()+keep);
    return s;
}

// ---------- per-key work ----------
static void process_key(const std::string &k, const std::string &host, int port) {
    thread_local std::unique_ptr<Redis> redis_conn;
    if (!redis_conn) redis_conn = std::make_unique<Redis>("tcp://" + host + ":" + std::to_string(port));

    try {
        auto raw = redis_conn->get(k);
        if (!raw) return;

        // allow either array-of-json or newline-delimited json
        std::vector<json> messages;
        try {
            json arr = json::parse(*raw);
            if (arr.is_array()) {
                messages.assign(arr.begin(), arr.end());
            } else {
                messages.push_back(arr);
            }
        } catch (...) {
            // try NDJSON fallback
            size_t start=0; const std::string &s=*raw;
            while (start<s.size()){
                size_t end = s.find('\n', start);
                if (end==std::string::npos) end=s.size();
                if (end>start) {
                    try { messages.push_back(json::parse(s.substr(start,end-start))); } catch(...) {}
                }
                start=end+1;
            }
        }

        auto mk = [&](const Stats& st){
            json j;
            j["spectrum"] = st.spectrum;

            if (std::isfinite(st.dominant_freq_hz))
                j["dominant_freq_hz"] = st.dominant_freq_hz;
            else
                j["dominant_freq_hz"] = nullptr;

            if (std::isfinite(st.mean))
                j["mean"] = st.mean;
            else
                j["mean"] = nullptr;

            if (std::isfinite(st.std_dev))
                j["std_dev"] = st.std_dev;
            else
                j["std_dev"] = nullptr;

            if (std::isfinite(st.min))
                j["min"] = st.min;
            else
                j["min"] = nullptr;

            if (std::isfinite(st.max))
                j["max"] = st.max;
            else
                j["max"] = nullptr;

            if (std::isfinite(st.std_dev) && st.std_dev>0 && std::isfinite(st.max) && std::isfinite(st.min))
                j["zspan"] = (st.max - st.min)/st.std_dev;
            else
                j["zspan"] = nullptr;

            return j;
        };

        json out;
        out["vehicle_count"] = mk(compute_stats(messages, "vehicle_count"));
        out["avg_speed"]     = mk(compute_stats(messages, "avg_speed"));
        out["occupancy"]     = mk(compute_stats(messages, "occupancy"));

        redis_conn->set(k + "_processed", out.dump());
        std::cout << "[INFO] Thread " << std::this_thread::get_id() << " processed key: " << k << "\n";
    } catch (const Error &e) {
        std::cerr << "[ERROR] Redis: " << e.what() << "\n";
    } catch (const std::exception &ex) {
        std::cerr << "[ERROR] Exception: " << ex.what() << "\n";
    }
}

// helper to filter out processed keys
static bool is_processed_key(const std::string &k) {
    const std::string suffix = "_processed";
    if (k.size() < suffix.size()) return false;
    return k.compare(k.size() - suffix.size(), suffix.size(), suffix) == 0;
}

int main() {
    const std::string mode         = std::getenv("MODE") ? std::getenv("MODE") : "native";
    const std::string redis_host   = std::getenv("REDIS_HOST") ? std::getenv("REDIS_HOST") : "127.0.0.1";
    const int         redis_port   = std::getenv("REDIS_PORT") ? std::stoi(std::getenv("REDIS_PORT")) : 6379;
    const int         thread_count = std::getenv("THREAD_COUNT") ? std::stoi(std::getenv("THREAD_COUNT")) : 2;
    const std::string key_pattern  = std::getenv("KEY_PATTERN") ? std::getenv("KEY_PATTERN") : "telemetry_*";

    fftw_global_init(thread_count);

    if (mode == "serverless") {
        std::atomic<bool> busy{false};
        httplib::Server svr;

        svr.Post("/run", [&](const httplib::Request &, httplib::Response &res) {
            if (busy.exchange(true)) { res.status=429; res.set_content("{\"status\":\"busy\"}","application/json"); return; }

            std::thread([&, redis_host, redis_port, thread_count, key_pattern]() {
                try {
                    Redis redis_main("tcp://" + redis_host + ":" + std::to_string(redis_port));
                    std::vector<std::string> keys;
                    redis_main.keys(key_pattern, std::back_inserter(keys));

                    // remove keys ending with _processed
                    keys.erase(
                        std::remove_if(keys.begin(), keys.end(), is_processed_key),
                        keys.end()
                    );

                    tbb::global_control limit(tbb::global_control::max_allowed_parallelism, thread_count);
                    tbb::task_arena arena(thread_count);
                    arena.execute([&]{
                        tbb::parallel_for(tbb::blocked_range<size_t>(0, keys.size(), 1),
                            [&](const tbb::blocked_range<size_t>& r){
                                for (size_t i=r.begin(); i!=r.end(); ++i)
                                    process_key(keys[i], redis_host, redis_port);
                            });
                    });
                } catch(...) {}
                busy=false;
            }).detach();

            res.set_content("{\"status\":\"processing\"}", "application/json");
        });

        svr.Get("/status", [&](const httplib::Request &, httplib::Response &res) {
            res.set_content(busy? "{\"status\":\"processing\"}" : "{\"status\":\"idle\"}", "application/json");
        });

        std::cout << "[INFO] Serverless mode on :8000\n";
        svr.listen("0.0.0.0",8000);
        return 0;
    }

    // native mode
    try {
        Redis redis_main("tcp://" + redis_host + ":" + std::to_string(redis_port));
        std::vector<std::string> keys;
        redis_main.keys(key_pattern, std::back_inserter(keys));

        // remove keys ending with _processed
        keys.erase(
            std::remove_if(keys.begin(), keys.end(), is_processed_key),
            keys.end()
        );

        tbb::global_control limit(tbb::global_control::max_allowed_parallelism, thread_count);
        tbb::task_arena arena(thread_count);
        arena.execute([&]{
            tbb::parallel_for(tbb::blocked_range<size_t>(0, keys.size(), 1),
                [&](const tbb::blocked_range<size_t>& r){
                    for (size_t i=r.begin(); i!=r.end(); ++i)
                        process_key(keys[i], redis_host, redis_port);
                });
        });
    } catch(const Error &e) {
        std::cerr << "[ERROR] Redis: " << e.what() << "\n";
    }
}

