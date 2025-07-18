from fastapi import FastAPI, Query, HTTPException
import time
from app.resize import download_and_resize
from app.upload import upload_image

app = FastAPI()

@app.get("/process")
def process_image(url: str = Query(...)):
    start = time.time()
    try:
        image_data, resized = download_and_resize(url)
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e))
    resize_time = time.time()

    upload_status = upload_image(resized)
    upload_time = time.time()

    return {
        "status": upload_status,
        "timing": {
            "total": round(upload_time - start, 2),
            "download_resize": round(resize_time - start, 2),
            "upload": round(upload_time - resize_time, 2)
        }
    }

