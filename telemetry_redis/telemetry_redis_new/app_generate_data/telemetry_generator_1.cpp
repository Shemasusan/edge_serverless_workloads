// telemetry_generator.cpp

#include <iostream>
#include <vector>
#include <random>
#include <chrono>
#include <string>
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
        {"avg_speed", round(speed_dist(gen) * 10) / 10.0},
        {"occupancy", round(occupancy_dist(gen) * 10) / 10.0},
        {"timestamp", std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::system_clock::now().time_since_epoch()).count() / 1000.0}
    };
    return record;
}

void generate_and_store(int proc_id, int record_count, Redis& redis) {
    // Create thread local RNG
    std::random_device rd;
    std::mt19937 gen(rd());

    json data = json::array();
    for (int i = 0; i < record_count; ++i) {
        data.push_back(generate_sensor_record(gen));
    }

    std::string key = "telemetry_" + std::to_string(proc_id) + "_" + std::to_string(
        std::chrono::steady_clock::now().time_since_epoch().count());

    redis.set(key, data.dump());
    std::cout << "[INFO] Stored " << record_count << " records to Redis key: " << key << std::endl;
}

int main(int argc, char* argv[]) {
    int record_count = 1000;
    int files_to_generate = 1;

    if (argc >= 2) {
        record_count = std::stoi(argv[1]);
    }
    if (argc >= 3) {
        files_to_generate = std::stoi(argv[2]);
    }

    Redis redis("tcp://127.0.0.1:6379");

    // Delete existing telemetry keys before generation
    std::vector<std::string> keys_to_delete;
    redis.keys("telemetry_*", std::back_inserter(keys_to_delete));
    if (!keys_to_delete.empty()) {
        redis.del(keys_to_delete.begin(), keys_to_delete.end());
        std::cout << "[INFO] Deleted " << keys_to_delete.size() << " existing telemetry keys from Redis" << std::endl;
    }

    tbb::parallel_for(tbb::blocked_range<int>(0, files_to_generate),
        [&](const tbb::blocked_range<int>& r) {
            for (int i = r.begin(); i < r.end(); ++i) {
                generate_and_store(i, record_count, redis);
            }
        });

    std::cout << "[INFO] Parallel generation done." << std::endl;

    return 0;
}

