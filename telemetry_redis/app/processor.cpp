// processor.cpp
#include <sw/redis++/redis++.h>
#include <nlohmann/json.hpp>
#include <fftw3.h>
#include <tbb/parallel_for.h>
#include <tbb/blocked_range.h>
#include <tbb/global_control.h>
#include "httplib.h" // cpp-httplib header-only server
#include <atomic>
#include <thread>
#include <iostream>
#include <vector>
#include <string>
#include <cmath>
#include <algorithm>
#include <chrono>
#include <cstdlib>
#include <mutex>

using json = nlohmann::json;
using namespace sw::redis;

struct Stats {
    double dominant_freq_hz;
    std::vector<double> spectrum; // first N magnitudes
    double mean;
    double std_dev;
    double min;
    double max;
};

// compute_stats function
Stats compute_stats(const std::vector<json> &messages, const std::string &key) {
    std::vector<double> values;
    std::vector<double> times;

    for (const auto &m : messages) {
        try {
            if (!m.contains(key) || !m.contains("timestamp")) continue;
            double v = m.at(key).get<double>();
            double t = m.at("timestamp").get<double>();
            if (std::isfinite(v) && std::isfinite(t)) {
                values.push_back(v);
                times.push_back(t);
            }
        } catch (...) {
            continue;
        }
    }

    Stats s;
    s.dominant_freq_hz = NAN;
    s.spectrum = {};
    s.mean = s.std_dev = s.min = s.max = NAN;
    if (values.size() < 2) {
        return s;
    }

    // Sort by time
    std::vector<size_t> idx(values.size());
    for (size_t i = 0; i < idx.size(); ++i) idx[i] = i;
    std::sort(idx.begin(), idx.end(), [&](size_t a, size_t b){ return times[a] < times[b]; });

    std::vector<double> t_sorted(values.size()), v_sorted(values.size());
    for (size_t i = 0; i < idx.size(); ++i) {
        t_sorted[i] = times[idx[i]];
        v_sorted[i] = values[idx[i]];
    }

    // normalize time to start at 0
    double t0 = t_sorted.front();
    for (auto &tt : t_sorted) tt -= t0;

    // resample to uniform grid
    size_t N = v_sorted.size();
    std::vector<double> uniform_t(N);
    double tmax = t_sorted.back();
    if (tmax <= 0) tmax = 1e-6;
    for (size_t i = 0; i < N; ++i) uniform_t[i] = (tmax * i) / (N - 1);

    // linear interpolation
    std::vector<double> v_interp(N);
    for (size_t i = 0; i < N; ++i) {
        double tt = uniform_t[i];
        auto it = std::lower_bound(t_sorted.begin(), t_sorted.end(), tt);
        if (it == t_sorted.begin()) {
            v_interp[i] = v_sorted.front();
        } else if (it == t_sorted.end()) {
            v_interp[i] = v_sorted.back();
        } else {
            size_t j = std::distance(t_sorted.begin(), it);
            size_t j0 = j - 1;
            double t0_ = t_sorted[j0], t1_ = t_sorted[j];
            double v0_ = v_sorted[j0], v1_ = v_sorted[j];
            double alpha = (tt - t0_) / (t1_ - t0_);
            v_interp[i] = v0_ + alpha * (v1_ - v0_);
        }
    }

    // compute basic stats
    double sum = 0.0;
    double sumsq = 0.0;
    double vmin = v_interp[0];
    double vmax = v_interp[0];
    for (double x : v_interp) {
        sum += x;
        sumsq += x*x;
        if (x < vmin) vmin = x;
        if (x > vmax) vmax = x;
    }
    double mean = sum / (double)N;
    double var = (sumsq / (double)N) - (mean*mean);
    double stddev = var > 0 ? std::sqrt(var) : 0.0;
    s.mean = mean;
    s.std_dev = stddev;
    s.min = vmin;
    s.max = vmax;

    // normalize signal
    std::vector<double> signal(N);
    double denom = std::sqrt(stddev*stddev) + 1e-12;
    for (size_t i = 0; i < N; ++i) signal[i] = (v_interp[i] - mean) / denom;

    // FFT using FFTW3
    size_t M = N;
    double *in = (double*) fftw_malloc(sizeof(double) * M);
    fftw_complex *out = (fftw_complex*) fftw_malloc(sizeof(fftw_complex) * (M/2 + 1));
    if (!in || !out) {
        if (in) fftw_free(in);
        if (out) fftw_free(out);
        return s;
    }

    for (size_t i = 0; i < M; ++i) in[i] = signal[i];
    fftw_plan plan = fftw_plan_dft_r2c_1d((int)M, in, out, FFTW_ESTIMATE);
    fftw_execute(plan);

    // compute magnitudes and frequencies
    std::vector<double> mags;
    std::vector<double> freqs;
    double dt = (M > 1) ? (uniform_t[1] - uniform_t[0]) : 1.0;
    for (size_t k = 0; k <= M/2; ++k) {
        double re = out[k][0];
        double im = out[k][1];
        double mag = std::sqrt(re*re + im*im);
        double freq = (double)k / (dt * (double)M);
        mags.push_back(mag);
        freqs.push_back(freq);
    }

    // find dominant frequency > 0
    double maxmag = -1.0;
    size_t maxidx = 0;
    for (size_t k = 1; k < mags.size(); ++k) {
        if (mags[k] > maxmag) {
            maxmag = mags[k];
            maxidx = k;
        }
    }
    s.dominant_freq_hz = (mags.size() > 1) ? freqs[maxidx] : NAN;
    size_t takeN = std::min((size_t)10, mags.size());
    s.spectrum.assign(mags.begin(), mags.begin() + takeN);

    fftw_destroy_plan(plan);
    fftw_free(in);
    fftw_free(out);

    return s;
}

// Function to process a single Redis key
void process_key(const std::string &k, const std::string &redis_host, int redis_port) {
    try {
        std::string conn = "tcp://" + redis_host + ":" + std::to_string(redis_port);
        Redis redis(conn);
        auto raw = redis.get(k);
        if (!raw) return;
        auto arr = json::parse(*raw);
        if (!arr.is_array()) return;

        std::vector<json> messages;
        messages.reserve(arr.size());
        for (const auto &item : arr) messages.push_back(item);

        json out;
        out["vehicle_count"] = json::object();
        out["avg_speed"] = json::object();
        out["occupancy"] = json::object();

        Stats sc = compute_stats(messages, "vehicle_count");
        Stats ss = compute_stats(messages, "avg_speed");
        Stats so = compute_stats(messages, "occupancy");

        auto fill_stats = [](const Stats &st) {
            json j;
            if (std::isfinite(st.dominant_freq_hz))
                j["dominant_freq_hz"] = st.dominant_freq_hz;
            else
                j["dominant_freq_hz"] = nullptr;

            j["spectrum"] = st.spectrum;

            if (!std::isnan(st.mean)) j["mean"] = st.mean; else j["mean"] = nullptr;
            if (!std::isnan(st.std_dev)) j["std_dev"] = st.std_dev; else j["std_dev"] = nullptr;
            if (!std::isnan(st.min)) j["min"] = st.min; else j["min"] = nullptr;
            if (!std::isnan(st.max)) j["max"] = st.max; else j["max"] = nullptr;

            return j;
        };

        out["vehicle_count"] = fill_stats(sc);
        out["avg_speed"] = fill_stats(ss);
        out["occupancy"] = fill_stats(so);

        std::string out_key = k + "_processed";
        redis.set(out_key, out.dump());
        std::cout << "[INFO] Thread " << std::this_thread::get_id() << " processed key: " << k << " -> " << out_key << "\n";
    } catch (const Error &e) {
        std::cerr << "[ERROR] Redis error for key " << k << ": " << e.what() << std::endl;
    } catch (const std::exception &ex) {
        std::cerr << "[ERROR] Exception for key " << k << ": " << ex.what() << std::endl;
    }
}

// Process all Redis keys
void process_all_files_sync(const std::string &redis_host, int redis_port, int core_count, bool threaded) {
    try {
        std::string conn = "tcp://" + redis_host + ":" + std::to_string(redis_port);
        Redis redis(conn);
        std::vector<std::string> keys;
        redis.keys("telemetry_*", std::back_inserter(keys));
        std::cout << "[INFO] Found " << keys.size() << " keys in Redis\n";
        if (keys.empty()) return;

        if (threaded) {
            tbb::global_control c(tbb::global_control::max_allowed_parallelism, core_count);
            tbb::parallel_for(tbb::blocked_range<size_t>(0, keys.size()), [&](const tbb::blocked_range<size_t>& r) {
                for (size_t i = r.begin(); i != r.end(); ++i) {
                    process_key(keys[i], redis_host, redis_port);
                }
            });
        } else {
            for (const auto &k : keys) {
                process_key(k, redis_host, redis_port);
            }
        }

        std::cout << "[INFO] Processing completed for all Redis keys\n";
    } catch (const Error &e) {
        std::cerr << "[FATAL] Redis connection error: " << e.what() << std::endl;
    }
}

// Global status with mutex
std::string g_status = "idle";
std::mutex g_status_mutex;
std::mutex g_proc_mutex;

// Wrapper for async HTTP processing
void process_all_files_http(const std::string &redis_host, int redis_port, int core_count, bool threaded) {
    {
        std::lock_guard<std::mutex> lock(g_proc_mutex);
        {
            std::lock_guard<std::mutex> status_lock(g_status_mutex);
            g_status = "processing";
        }
    }
    process_all_files_sync(redis_host, redis_port, core_count, threaded);
    {
        std::lock_guard<std::mutex> status_lock(g_status_mutex);
        g_status = "done";
    }
}

// Read MODE env var
std::string get_mode() {
    const char *env_mode = std::getenv("MODE");
    return env_mode ? std::string(env_mode) : "native_st";
}

// Read env var with default
std::string get_env(const char *key, const std::string &def) {
    const char *val = std::getenv(key);
    return val ? std::string(val) : def;
}

int main(int argc, char **argv) {
    std::string mode = get_mode();
    std::string redis_host = get_env("REDIS_HOST", "127.0.0.1");
    int redis_port = std::stoi(get_env("REDIS_PORT", "6379"));
    int core_count = std::stoi(get_env("CORE_COUNT", "1"));
    bool threaded = (get_env("THREADED", "false") == "true");

    if (mode.rfind("native", 0) == 0 || mode.rfind("container", 0) == 0) {
        // Run synchronously for native* and container* modes
        std::cout << "[INFO] Running in mode: " << mode << " (synchronous)" << std::endl;
        process_all_files_sync(redis_host, redis_port, core_count, threaded);
        return 0;
    } else if (mode.rfind("serverless", 0) == 0) {
        // Run with HTTP server for serverless*
        std::cout << "[INFO] Running in serverless mode: " << mode << std::endl;
        httplib::Server svr;

        svr.Post("/run", [&](const httplib::Request&, httplib::Response &res) {
            {
                std::lock_guard<std::mutex> status_lock(g_status_mutex);
                if (g_status == "processing") {
                    res.set_content("{\"status\": \"processing\"}", "application/json");
                    return;
                }
                g_status = "processing";
            }
            std::thread(process_all_files_http, redis_host, redis_port, core_count, threaded).detach();
            res.set_content("{\"status\": \"processing_started\"}", "application/json");
        });

        svr.Get("/status", [&](const httplib::Request&, httplib::Response &res) {
            std::string s;
            {
                std::lock_guard<std::mutex> status_lock(g_status_mutex);
                s = g_status;
            }
            std::string body = "{\"status\": \"" + s + "\"}";
            res.set_content(body, "application/json");
        });

        std::cout << "[INFO] Starting HTTP server on port 8000" << std::endl;
        svr.listen("0.0.0.0", 8000);
        return 0;
    } else {
        std::cerr << "[ERROR] Unknown MODE: " << mode << std::endl;
        return 1;
    }
}

