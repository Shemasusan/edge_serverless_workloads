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

using json = nlohmann::json;
using namespace sw::redis;

struct Stats {
    double dominant_freq_hz;
    std::vector<double> spectrum;
    double mean;
    double std_dev;
    double min;
    double max;
};

std::mutex fftw_mutex;
bool fftw_initialized = false;

void fftw_initialize(int threads) {
    std::lock_guard<std::mutex> lock(fftw_mutex);
    if (!fftw_initialized) {
        fftw_init_threads();
        fftw_plan_with_nthreads(threads);
        fftw_initialized = true;
    }
}

Stats compute_stats(const std::vector<json> &messages, const std::string &key) {
    std::vector<double> values, times;
    for (const auto &m : messages) {
        if (!m.contains(key) || !m.contains("timestamp")) continue;
        try {
            double v = m.at(key).get<double>();
            double t = m.at("timestamp").get<double>();
            if (std::isfinite(v) && std::isfinite(t)) {
                values.push_back(v);
                times.push_back(t);
            }
        } catch (...) { continue; }
    }

    Stats s;
    s.dominant_freq_hz = NAN;
    s.mean = s.std_dev = s.min = s.max = NAN;
    if (values.size() < 2) return s;

    // sort by time
    std::vector<size_t> idx(values.size());
    for (size_t i = 0; i < idx.size(); i++) idx[i] = i;
    std::sort(idx.begin(), idx.end(), [&](size_t a, size_t b){ return times[a] < times[b]; });

    std::vector<double> t_sorted(values.size()), v_sorted(values.size());
    for (size_t i = 0; i < idx.size(); i++) {
        t_sorted[i] = times[idx[i]];
        v_sorted[i] = values[idx[i]];
    }

    double t0 = t_sorted.front();
    for(auto &tt: t_sorted) tt -= t0;

    size_t N = v_sorted.size();
    std::vector<double> uniform_t(N);
    double tmax = t_sorted.back();
    if(tmax <= 0) tmax = 1e-6;
    for(size_t i = 0; i < N; i++) uniform_t[i] = tmax * i / (N - 1);

    // linear interp
    std::vector<double> v_interp(N);
    for(size_t i = 0; i < N; i++){
        double tt = uniform_t[i];
        auto it = std::lower_bound(t_sorted.begin(), t_sorted.end(), tt);
        if(it == t_sorted.begin()) v_interp[i] = v_sorted.front();
        else if(it == t_sorted.end()) v_interp[i] = v_sorted.back();
        else {
            size_t j = std::distance(t_sorted.begin(), it);
            size_t j0 = j - 1;
            double t0_ = t_sorted[j0], t1_ = t_sorted[j];
            double v0_ = v_sorted[j0], v1_ = v_sorted[j];
            double alpha = (tt - t0_) / (t1_ - t0_);
            v_interp[i] = v0_ + alpha * (v1_ - v0_);
        }
    }

    // basic stats
    double sum = 0, sumsq = 0;
    double vmin = v_interp[0], vmax = v_interp[0];
    for(double x : v_interp){
        sum += x; sumsq += x * x;
        if(x < vmin) vmin = x;
        if(x > vmax) vmax = x;
    }
    double mean = sum / N;
    double var = (sumsq / N) - (mean * mean);
    double stddev = var > 0 ? std::sqrt(var) : 0.0;
    s.mean = mean; s.std_dev = stddev; s.min = vmin; s.max = vmax;

    // normalize
    std::vector<double> signal(N);
    double denom = stddev + 1e-12;
    for(size_t i = 0; i < N; i++) signal[i] = (v_interp[i] - mean) / denom;

    // FFT
    double *in = (double*)fftw_malloc(sizeof(double) * N);
    fftw_complex *out = (fftw_complex*)fftw_malloc(sizeof(fftw_complex) * (N/2+1));
    if(!in || !out){ if(in) fftw_free(in); if(out) fftw_free(out); return s; }
    for(size_t i = 0; i < N; i++) in[i] = signal[i];
    fftw_plan plan;
    { std::lock_guard<std::mutex> lock(fftw_mutex); plan = fftw_plan_dft_r2c_1d((int)N, in, out, FFTW_ESTIMATE); }
    fftw_execute(plan);

    std::vector<double> mags, freqs;
    double dt = (N > 1) ? (uniform_t[1] - uniform_t[0]) : 1.0;
    for(size_t k = 0; k <= N/2; k++){
        double re = out[k][0], im = out[k][1];
        mags.push_back(std::sqrt(re*re + im*im));
        freqs.push_back(k / (dt * N));
    }

    double maxmag = -1.0; size_t maxidx = 0;
    for(size_t k = 1; k < mags.size(); k++){ if(mags[k] > maxmag){ maxmag = mags[k]; maxidx = k; } }
    s.dominant_freq_hz = (mags.size() > 1) ? freqs[maxidx] : NAN;
    s.spectrum.assign(mags.begin(), mags.begin() + std::min((size_t)10, mags.size()));

    fftw_destroy_plan(plan);
    fftw_free(in); fftw_free(out);

    return s;
}

void process_key(const std::string &k, const std::string &host, int port) {
    thread_local std::unique_ptr<Redis> redis_conn;
    if(!redis_conn) redis_conn = std::make_unique<Redis>("tcp://" + host + ":" + std::to_string(port));

    try {
        auto raw = redis_conn->get(k);
        if(!raw) return;
        auto arr = json::parse(*raw);
        if(!arr.is_array()) return;

        std::vector<json> messages(arr.begin(), arr.end());
        json out;

        auto fill_stats = [&](const Stats &st) {
            json j;
            if (std::isfinite(st.dominant_freq_hz)) j["dominant_freq_hz"] = st.dominant_freq_hz;
            else j["dominant_freq_hz"] = nullptr;

            j["spectrum"] = st.spectrum;

            if (std::isfinite(st.mean)) j["mean"] = st.mean;
            else j["mean"] = nullptr;

            if (std::isfinite(st.std_dev)) j["std_dev"] = st.std_dev;
            else j["std_dev"] = nullptr;

            if (std::isfinite(st.min)) j["min"] = st.min;
            else j["min"] = nullptr;

            if (std::isfinite(st.max)) j["max"] = st.max;
            else j["max"] = nullptr;

            return j;
        };

        out["vehicle_count"] = fill_stats(compute_stats(messages, "vehicle_count"));
        out["avg_speed"] = fill_stats(compute_stats(messages, "avg_speed"));
        out["occupancy"] = fill_stats(compute_stats(messages, "occupancy"));

        redis_conn->set(k + "_processed", out.dump());
        std::cout << "[INFO] Thread " << std::this_thread::get_id() << " processed key: " << k << "\n";

    } catch (const Error &e) { std::cerr << "[ERROR] Redis error: " << e.what() << "\n"; }
      catch (const std::exception &ex) { std::cerr << "[ERROR] Exception: " << ex.what() << "\n"; }
}

int main() {
    std::string redis_host = std::getenv("REDIS_HOST") ? std::getenv("REDIS_HOST") : "127.0.0.1";
    int redis_port = std::getenv("REDIS_PORT") ? std::stoi(std::getenv("REDIS_PORT")) : 6379;
    int thread_count = std::getenv("THREAD_COUNT") ? std::stoi(std::getenv("THREAD_COUNT")) : 8;

    fftw_initialize(thread_count);

    Redis redis_main("tcp://" + redis_host + ":" + std::to_string(redis_port));
    std::vector<std::string> keys;
    redis_main.keys("telemetry_*", std::back_inserter(keys));
    std::cout << "[INFO] Found " << keys.size() << " keys in Redis\n";
    if (keys.empty()) return 0;

    // Force TBB to create exactly thread_count threads
    tbb::global_control global_limit(tbb::global_control::max_allowed_parallelism, thread_count);
    tbb::task_arena arena(thread_count);
    arena.execute([&] {
        tbb::parallel_for(
            tbb::blocked_range<size_t>(0, keys.size(), 1),
            [&](const tbb::blocked_range<size_t>& r) {
                for (size_t i = r.begin(); i != r.end(); ++i)
                    process_key(keys[i], redis_host, redis_port);
            }
        );
    });

    return 0;
}

