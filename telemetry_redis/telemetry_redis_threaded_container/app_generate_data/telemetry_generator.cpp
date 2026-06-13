#include <iostream>
#include <vector>
#include <random>
#include <chrono>
#include <string>
#include <cstdlib>
#include <cmath>

#include <tbb/parallel_for.h>
#include <tbb/blocked_range.h>
#include <sw/redis++/redis++.h>
#include <nlohmann/json.hpp>

using json = nlohmann::json;
using namespace sw::redis;

std::vector<int> sensor_ids = {1001, 1002, 1003};

json generate_sensor_record(std::mt19937& gen) {
    std::uniform_int_distribution<> vehicle_count_dist(0, 20);
    std::uniform_real_distribution<> speed_dist(0, 120);
    std::uniform_real_distribution<> occupancy_dist(0, 100);
    std::uniform_int_distribution<> sensor_dist(0, sensor_ids.size() - 1);

    json record = {
        {"sensor_id", sensor_ids[sensor_dist(gen)]},
        {"vehicle_count", vehicle_count_dist(gen)},
        {"avg_speed", std::round(speed_dist(gen) * 10) / 10.0},
        {"occupancy", std::round(occupancy_dist(gen) * 10) / 10.0},
        {"timestamp", std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::system_clock::now().time_since_epoch()).count() / 1000.0}
    };
    return record;
}

void generate_and_store(int proc_id,
                        int record_count,
                        const std::string& redis_uri,
                        const std::string& run_id) {
    // Thread-local Redis client
    Redis redis(redis_uri);

    // Thread-local RNG
    std::random_device rd;
    std::mt19937 gen(rd());

    json data = json::array();
    for (int i = 0; i < record_count; ++i) {
        data.push_back(generate_sensor_record(gen));
    }

    std::string key = "telemetry_" + run_id + "_" +
                      std::to_string(proc_id) + "_" +
                      std::to_string(std::chrono::steady_clock::now().time_since_epoch().count());

    redis.set(key, data.dump());
    std::cout << "[INFO] Stored " << record_count
              << " records to Redis key: " << key << std::endl;
}

int main(int argc, char* argv[]) {
    int record_count = 1000;
    int files_to_generate = 1;

    std::string redis_host = "127.0.0.1";
    int redis_port = 6379;

    const char* run_id_env = std::getenv("RUN_ID");
    std::string run_id = run_id_env ? run_id_env : "default";

    if (argc >= 2) record_count = std::stoi(argv[1]);
    if (argc >= 3) files_to_generate = std::stoi(argv[2]);
    if (argc >= 4) redis_host = argv[3];
    if (argc >= 5) redis_port = std::stoi(argv[4]);

    if (argc < 4) {
        if (const char* env_host = std::getenv("REDIS_HOST")) {
            redis_host = env_host;
        }
    }
    if (argc < 5) {
        if (const char* env_port = std::getenv("REDIS_PORT")) {
            redis_port = std::stoi(env_port);
        }
    }

    std::string redis_uri = "tcp://" + redis_host + ":" + std::to_string(redis_port);
    std::cout << "[INFO] Connecting to Redis at " << redis_uri
              << " for RUN_ID=" << run_id << std::endl;

    // Single client for one-time cleanup only
    Redis cleanup_redis(redis_uri);

    std::vector<std::string> keys_to_delete;
    std::string pattern = "telemetry_" + run_id + "_*";
    cleanup_redis.keys(pattern, std::back_inserter(keys_to_delete));

    if (!keys_to_delete.empty()) {
        cleanup_redis.del(keys_to_delete.begin(), keys_to_delete.end());
        std::cout << "[INFO] Deleted " << keys_to_delete.size()
                  << " old telemetry keys for run " << run_id << std::endl;
    }

    tbb::parallel_for(tbb::blocked_range<int>(0, files_to_generate),
        [&](const tbb::blocked_range<int>& r) {
            for (int i = r.begin(); i < r.end(); ++i) {
                generate_and_store(i, record_count, redis_uri, run_id);
            }
        });

    std::cout << "[INFO] Parallel generation done." << std::endl;
    return 0;
}
