import multiprocessing as mp
mp.set_start_method("spawn", force=True)

from fastapi import FastAPI
from pydantic import BaseModel
from threading import Thread
from app.process_data import process_all_files

app = FastAPI()
app.state.done = "idle"  # idle, processing, done, error

class RunRequest(BaseModel):
    core_count: int
    mode: str
    threaded: bool

@app.post("/run")
def run_workload(req: RunRequest):
    app.state.done = "processing"

    def background_processing():
        try:
            print("[INFO] Background processing started")
            process_all_files(req.core_count, req.threaded)
            print("[INFO] Background processing finished")
            app.state.done = "done"
        except Exception as e:
            print(f"[ERROR] Exception in background processing: {e}")
            app.state.done = "error"

    Thread(target=background_processing).start()
    return {"status": "started"}

@app.get("/status")
def check_status():
    return {"status": app.state.done}

