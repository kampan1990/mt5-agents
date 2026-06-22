"""
main.py — FastAPI backend for CME Gold Vol2Vol analyzer
GET  / → serve HTML frontend
POST /analyze → scrape CME + analyze with Claude
"""

from fastapi import FastAPI, Request
from fastapi.responses import HTMLResponse, JSONResponse
from fastapi.templating import Jinja2Templates
import traceback

from scraper import scrape_gold_data
from analyzer import analyze_gold_data

app = FastAPI(title="CME Gold Vol2Vol Analyzer")
templates = Jinja2Templates(directory="templates")


@app.get("/", response_class=HTMLResponse)
async def index(request: Request):
    """Serve the main HTML frontend."""
    return templates.TemplateResponse("index.html", {"request": request})


@app.post("/analyze")
async def analyze():
    """
    Scrape CME Vol2Vol Expected Range for Gold, then analyze with Claude AI.

    Returns:
        JSON with: signal, confidence, analysis, range_high, range_low,
                   current_price, date, error (if any)
    """
    try:
        # Step 1: Scrape CME data
        gold_data = scrape_gold_data()

        # Step 2: Analyze with Claude
        result = analyze_gold_data(gold_data)

        # Enrich result with raw scraped data
        result["current_price"] = gold_data.get("current_price")
        result["date"] = gold_data.get("date")
        result["implied_volatility"] = gold_data.get("implied_volatility")

        return JSONResponse(content=result)

    except Exception as e:
        tb = traceback.format_exc()
        print(f"[ERROR] /analyze failed:\n{tb}")
        return JSONResponse(
            status_code=500,
            content={
                "error": str(e),
                "signal": None,
                "confidence": None,
                "analysis": None,
            }
        )


if __name__ == "__main__":
    import uvicorn
    uvicorn.run("main:app", host="0.0.0.0", port=8000, reload=True)
