"""
scraper.py — CME Vol2Vol Expected Range scraper
Uses undetected-chromedriver to bypass Cloudflare bot detection.
Filters for Gold (GC) and returns structured data.
"""

import time
import re
import undetected_chromedriver as uc
from selenium.webdriver.common.by import By
from selenium.webdriver.support.ui import WebDriverWait
from selenium.webdriver.support import expected_conditions as EC
from config import CME_URL


def scrape_gold_data() -> dict:
    """
    Scrape CME Vol2Vol Expected Range page for Gold (GC) data.

    Returns:
        dict with keys: date, range_high, range_low, current_price, implied_volatility
    Raises:
        RuntimeError: if scraping fails or Gold data not found
    """
    options = uc.ChromeOptions()
    options.add_argument("--headless=new")
    options.add_argument("--no-sandbox")
    options.add_argument("--disable-dev-shm-usage")
    options.add_argument("--disable-gpu")
    options.add_argument("--window-size=1920,1080")

    driver = uc.Chrome(options=options, use_subprocess=True)
    try:
        driver.get(CME_URL)

        # Wait for the data table to appear (up to 30 seconds)
        wait = WebDriverWait(driver, 30)
        wait.until(EC.presence_of_element_located((By.TAG_NAME, "table")))

        # Additional wait for JS to fully render
        time.sleep(5)

        # Find all tables on the page
        tables = driver.find_elements(By.TAG_NAME, "table")
        gold_data = None

        for table in tables:
            rows = table.find_elements(By.TAG_NAME, "tr")
            for row in rows:
                cells = row.find_elements(By.TAG_NAME, "td")
                if not cells:
                    cells = row.find_elements(By.TAG_NAME, "th")

                cell_texts = [c.text.strip() for c in cells]
                row_text = " ".join(cell_texts).upper()

                # Look for Gold / GC rows
                if "GC" in row_text or "GOLD" in row_text:
                    gold_data = _parse_gold_row(cell_texts)
                    if gold_data:
                        break
            if gold_data:
                break

        if not gold_data:
            # Fallback: search all page text for Gold data
            page_text = driver.find_element(By.TAG_NAME, "body").text
            gold_data = _parse_from_text(page_text)

        if not gold_data:
            raise RuntimeError("Gold (GC) data not found on CME page")

        return gold_data

    finally:
        driver.quit()


def _parse_gold_row(cells: list) -> dict | None:
    """
    Parse a table row's cell texts into Gold data dict.
    Expects cells to contain: symbol, date, range_high, range_low, current_price, IV
    """
    # Filter out empty cells
    non_empty = [c for c in cells if c]
    if len(non_empty) < 4:
        return None

    numbers = []
    date_str = ""

    for cell in non_empty:
        # Check if cell looks like a date
        if re.search(r'\d{1,2}[/-]\d{1,2}[/-]\d{2,4}', cell) or \
           re.search(r'(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)', cell, re.I):
            date_str = cell
        else:
            # Try to extract a number
            num_match = re.search(r'[\d,]+\.?\d*', cell.replace(',', ''))
            if num_match:
                try:
                    numbers.append(float(num_match.group().replace(',', '')))
                except ValueError:
                    pass

    if len(numbers) < 3:
        return None

    # Heuristic: largest numbers are range high/current price, smallest is range low
    numbers_sorted = sorted(numbers, reverse=True)

    return {
        "date": date_str or "N/A",
        "range_high": numbers_sorted[0],
        "range_low": numbers_sorted[-1] if len(numbers_sorted) > 1 else numbers_sorted[0],
        "current_price": numbers_sorted[1] if len(numbers_sorted) > 2 else numbers_sorted[0],
        "implied_volatility": numbers[-1] if numbers[-1] < 100 else None,
    }


def _parse_from_text(page_text: str) -> dict | None:
    """
    Fallback parser that searches raw page text for Gold data.
    """
    lines = page_text.split('\n')
    for i, line in enumerate(lines):
        if 'GC' in line.upper() or 'GOLD' in line.upper():
            # Collect surrounding lines and look for numbers
            context = " ".join(lines[max(0, i-1):i+5])
            numbers = re.findall(r'\b\d{3,5}\.?\d*\b', context)
            if len(numbers) >= 2:
                nums = [float(n) for n in numbers]
                nums_sorted = sorted(nums, reverse=True)
                date_match = re.search(
                    r'\d{1,2}[/-]\d{1,2}[/-]\d{2,4}', context)
                return {
                    "date": date_match.group() if date_match else "N/A",
                    "range_high": nums_sorted[0],
                    "range_low": nums_sorted[-1],
                    "current_price": nums_sorted[1] if len(nums_sorted) > 2 else nums_sorted[0],
                    "implied_volatility": None,
                }
    return None
