import os
from dotenv import load_dotenv

load_dotenv()

ANTHROPIC_API_KEY = os.getenv("ANTHROPIC_API_KEY", "")
CME_URL = "https://www.cmegroup.com/tools-information/quikstrike/vol2vol-expected-range.html"
