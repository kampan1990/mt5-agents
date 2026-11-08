"""Layer 7: วิเคราะห์ journal ที่ EA บันทึก (GinzaJo_journal.csv) — signal ไหนกำไร/ขาดทุน, session ไหนเหมาะ, โมเดลเสื่อมไหม

ใช้: python analyze_journal.py GinzaJo_journal.csv
คอลัมน์: time,event,ticket,dir,lot,price,sl,tp,prob_buy,prob_sell,score,hour,spread,atr,profit
(event = OPEN | CLOSE ; profit มีเฉพาะ CLOSE)
"""
import sys
import numpy as np
import pandas as pd


def main(path):
    j = pd.read_csv(path)
    o = j[j.event == "OPEN"].set_index("ticket")
    c = j[j.event == "CLOSE"].set_index("ticket")
    t = o.join(c[["profit", "time"]], rsuffix="_close", how="inner")
    if t.empty:
        print("ยังไม่มีออเดอร์ที่ปิดแล้ว"); return
    risk = (abs(t.price - t.sl) / t.atr).replace(0, np.nan)  # เศษส่วนของ ATR ที่เสี่ยง
    t["win"] = t.profit > 0
    print(f"เทรดที่ปิดแล้ว {len(t)} | win {t.win.mean():.1%} | net {t.profit.sum():.2f} | "
          f"avg win {t.profit[t.win].mean():.2f} | avg loss {t.profit[~t.win].mean():.2f}")

    def grp(title, key):
        g = t.groupby(key).agg(n=("profit", "size"), win=("win", "mean"), net=("profit", "sum"), avg=("profit", "mean"))
        print(f"\n-- {title}\n{g.round(3).to_string()}")

    grp("ตามทิศ (dir: 1=BUY,-1=SELL)", "dir")
    t["session"] = pd.cut(t.hour, [-1, 6, 12, 20, 23], labels=["asia", "london", "newyork", "late"])
    grp("ตาม session (เวลาเซิร์ฟเวอร์)", "session")
    t["conf"] = pd.cut(np.where(t.dir == 1, t.prob_buy, t.prob_sell), [0, .5, .55, .6, 1])
    grp("ตามความมั่นใจของโมเดล", "conf")

    # ตรวจการเสื่อม: expectancy ของ 30 เทรดล่าสุด เทียบทั้งหมด
    if len(t) >= 60:
        recent, base = t.profit.tail(30).mean(), t.profit.mean()
        print(f"\nrolling 30 เทรดล่าสุด: avg {recent:.2f} vs ทั้งหมด {base:.2f}")
        if recent < 0 < base or recent < base * 0.3:
            print("!! โมเดลอาจเริ่มเสื่อม — ลดขนาด lot / หยุดแล้วเทรนใหม่ด้วยข้อมูลล่าสุด")


if __name__ == "__main__":
    main(sys.argv[1])
