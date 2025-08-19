#include <iostream>
#include <vector>
#include <string>
#include <chrono>
#include <thread>
#include <mutex>
#include <cstdlib>
#include <ctime>
#include <sstream>

#include <hiredis/hiredis.h>
#include <nlohmann/json.hpp>
#include <uuid/uuid.h>

using json = nlohmann::json;

// Mutex for printing from multiple threads
std::mutex print_mutex;

// ---------- Sensor Data Simulation ----------
json generate_sensor_data(int record_count) {
    json data = json::array();
    for (int i = 0; i < record_count; ++i) {
        data.push_back({
            {"id", i},
            {"timestamp", std::time(nullptr)},
            {"value", rand() % 100}
        });
    }
    return data;
}

// ---------- UUID Generation ----------
std::string generate_uuid() {
    uuid_t binuuid;
    uuid_generate_random(binuuid);
    char uuid_str[37];
    uuid_unparse_lower(binuuid, uuid_str);
    return std::string(uuid_str);
}

// ---------- Redis Client ----------
redisContext* connect_redis(const std::string& host="127.0.0.1", int port=6379) {
    redisContext* c = redisConnect(host.c_str(), port);
    if (c == nullptr || c->err) {
        if (c) std::cerr << "[ERROR] Redis connection error: " << c->errstr << std::endl;
        else std::cerr << "[ERROR] Redis connection error: can't allocate context" << std::endl;
        exit(1);
    }
    return c;
}

// ---------- Clear existing telemetry keys ----------
void clear_redis_keys(redisContext* c) {
    redisReply* keys_reply = (redisReply*) redisCommand(c, "KEYS telemetry_*");
    if (keys_reply && keys_reply->type == REDIS_REPLY_ARRAY) {
        for (size_t i = 0; i < keys_reply->elements; ++i) {
            const char* key = keys_reply->element[i]->str;
            redisCommand(c, "DEL %s", key);
        }
    }
    if (keys_reply) freeReplyObject(keys_reply);
}

// ---------- Generate & Push Data ----------
void generate_file(int proc_id, int record_count) {
    auto start = std::chrono::high_resolution_clock::now();

    json data = generate_sensor_data(record_count);
    std::string redis_key = "telemetry_" + std::to_string(proc_id) + "_" + generate_uuid();

    redisContext* c = connect_redis();
    redisReply* reply = (redisReply*) redisCommand(c, "SET %s %s", redis_key.c_str(), data.dump().c_str());
    freeReplyObject(reply);
    redisFree(c);

    auto end = std::chrono::high_resolution_clock::now();
    double latency = std::chrono::duration<double>(end - start).count();

    std::lock_guard<std::mutex> lock(print_mutex);
    std::cout << "[INFO] Generated " << record_count 
              << " records, key=" << redis_key 
              << ", latency=" << latency << "s" << std::endl;
}

// ---------- Run Sequential ----------
void run_sequential(int record_count, int files_to_generate) {
    for (int i = 0; i < files_to_generate; ++i) {
        generate_file(i, record_count);
    }
    std::cout << "[INFO] Sequential generation done." << std::endl;
}

// ---------- Run Parallel ----------
void run_parallel(int record_count, int files_to_generate) {
    std::vector<std::thread> threads;
    for (int i = 0; i < files_to_generate; ++i) {
        threads.emplace_back(generate_file, i, record_count);
    }

    for (auto &t : threads) t.join();

    std::cout << "[INFO] Parallel generation done." << std::endl;
}

// ---------- Main ----------
int main(int argc, char* argv[]) {
    srand(time(nullptr));

    int record_count = 1000;
    int files_to_generate = 1;
    bool threaded = false;

    // Simple env variable handling
    if (const char* env_count = std::getenv("RECORDS")) record_count = std::stoi(env_count);
    if (const char* env_files = std::getenv("FILES_TO_GENERATE")) files_to_generate = std::stoi(env_files);
    if (const char* env_threaded = std::getenv("THREADED")) {
        std::string th(env_threaded);
        threaded = (th == "true" || th == "1");
    }

    // Connect to Redis once and clear previous telemetry keys
    redisContext* c = connect_redis();
    clear_redis_keys(c);
    redisFree(c);

    // Generate new telemetry files
    if (threaded) run_parallel(record_count, files_to_generate);
    else run_sequential(record_count, files_to_generate);

    return 0;
}

