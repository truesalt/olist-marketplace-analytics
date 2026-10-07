"""Build the 7 README charts (matplotlib, 150 dpi) from results/ CSVs (+ one mart for Pareto).

    python python/make_charts.py

Inputs : results/sql/*.csv (analysis outputs), MySQL mart_pareto_sellers (Pareto curve)
Outputs: results/charts/01_monthly_gmv.png ... 07_lane_late_heatmap.png

Design rules (kept deliberately simple):
  * one y-axis per chart (never dual axes); money axes formatted as R$
  * one blue for single-series charts; a diverging red <-> gray <-> blue scale for review scores
    (bad vs good); a light->dark blue scale for magnitudes in heatmaps
  * hairline grid, no top/right spines, labels in neutral ink (never the series color)
"""
from __future__ import annotations

import sys
from pathlib import Path

import matplotlib

matplotlib.use("Agg")                     # headless: render straight to files
import matplotlib.pyplot as plt           # noqa: E402
import numpy as np                        # noqa: E402
import pandas as pd                       # noqa: E402
from matplotlib.colors import LinearSegmentedColormap  # noqa: E402
from matplotlib.ticker import FuncFormatter, PercentFormatter  # noqa: E402
from statsmodels.stats.proportion import proportion_confint  # noqa: E402

sys.path.insert(0, str(Path(__file__).resolve().parent))
from db import REPO_ROOT, get_engine  # noqa: E402

SQL_DIR = REPO_ROOT / "results" / "sql"
CHART_DIR = REPO_ROOT / "results" / "charts"

# Validated reference palette (light mode)
INK, INK_2, GRID, SURFACE = "#0b0b0b", "#52514e", "#e1e0d9", "#fcfcfb"
BLUE, ORANGE = "#2a78d6", "#eb6834"
BLUE_RAMP = ["#cde2fb", "#9ec5f4", "#6da7ec", "#3987e5", "#256abf", "#184f95", "#0d366b"]
SCORE_COLORS = {1: "#c23434", 2: "#ec8f8e", 3: "#d9d8d3", 4: "#86b6ef", 5: "#256abf"}

plt.rcParams.update({
    "figure.dpi": 150, "savefig.dpi": 150, "figure.facecolor": SURFACE, "axes.facecolor": SURFACE,
    "font.size": 9.5, "axes.titlesize": 12, "axes.titleweight": "bold", "axes.titlelocation": "left",
    "axes.edgecolor": INK_2, "axes.labelcolor": INK_2, "xtick.color": INK_2, "ytick.color": INK_2,
    "text.color": INK, "axes.spines.top": False, "axes.spines.right": False,
    "axes.grid": True, "grid.color": GRID, "grid.linewidth": 0.6, "axes.axisbelow": True,
    "legend.frameon": False,
})


def brl(x: float, _pos=None) -> str:
    """R$ axis formatter: R$ 1.2M / R$ 350k."""
    if abs(x) >= 1e6:
        return f"R$ {x / 1e6:.1f}M"
    if abs(x) >= 1e3:
        return f"R$ {x / 1e3:.0f}k"
    return f"R$ {x:.0f}"


def read(name: str) -> pd.DataFrame:
    return pd.read_csv(SQL_DIR / f"{name}.csv")


def save(fig, filename: str, source: str) -> None:
    # Place the source line under everything already drawn (rotated tick labels included).
    fig.canvas.draw()
    box = fig.get_tightbbox(fig.canvas.get_renderer())
    fig.text(box.x0 / fig.get_figwidth(), box.y0 / fig.get_figheight() - 0.02, f"Source: {source}",
             fontsize=7.5, color=INK_2, va="top")
    fig.savefig(CHART_DIR / filename, bbox_inches="tight", facecolor=SURFACE)
    plt.close(fig)
    print(f"saved results/charts/{filename}")


def chart_monthly_gmv() -> None:
    df = read("a02_monthly_trends__monthly_trend")
    x = np.arange(len(df))
    fig, ax = plt.subplots(figsize=(10, 4.6))
    ax.bar(x, df["gmv_brl"], width=0.72, color=BLUE, alpha=0.55, label="Monthly GMV")
    ax.plot(x, df["gmv_3m_moving_avg"], color=ORANGE, linewidth=2, label="3-month moving average")
    peak = df["gmv_brl"].idxmax()
    ax.annotate(f"Black Friday peak\n{brl(df.loc[peak, 'gmv_brl'])} ({df.loc[peak, 'year_month']})",
                xy=(peak - 0.4, df.loc[peak, "gmv_brl"]), xytext=(peak - 1.0, df.loc[peak, "gmv_brl"] * 0.97),
                ha="right", va="center", fontsize=8.5, color=INK,
                arrowprops={"arrowstyle": "-", "color": INK_2, "linewidth": 0.8})
    ax.set_xticks(x)
    ax.set_xticklabels(df["year_month"], rotation=45, ha="right")
    ax.yaxis.set_major_formatter(FuncFormatter(brl))
    ax.set_ylabel("GMV (price + freight)")
    ax.set_xlabel("Purchase month")
    growth = df["gmv_brl"].max() / df["gmv_brl"].iloc[0]
    ax.set_title(f"Monthly GMV rose {growth:.1f}x from Jan-2017 to the Nov-2017 peak, then plateaued in 2018")
    ax.grid(axis="x", visible=False)
    ax.legend(loc="upper left", bbox_to_anchor=(0.0, 0.88))
    save(fig, "01_monthly_gmv.png", "results/sql/a02_monthly_trends__monthly_trend.csv")


def chart_review_by_delay() -> None:
    df = read("a05_delay_vs_review__review_by_delay_bucket")
    df = df.iloc[::-1].reset_index(drop=True)          # earliest bucket on top
    fig, ax = plt.subplots(figsize=(10, 4.4))
    left = np.zeros(len(df))
    for score in [1, 2, 3, 4, 5]:
        vals = df[f"score_{score}_pct"].to_numpy()
        ax.barh(df["delay_bucket"], vals, left=left, color=SCORE_COLORS[score], height=0.62,
                edgecolor=SURFACE, linewidth=1.2, label=f"{score} star{'s' if score > 1 else ''}")
        left += vals
    for i, row in df.iterrows():                         # label only the headline: low-review share
        ax.text(101, i, f"{row['low_review_pct']:.1f}% low (1-2★)  ·  n={row['reviewed_orders']:,}",
                va="center", fontsize=8.5, color=INK)
    ax.set_xlim(0, 100)
    ax.xaxis.set_major_formatter(PercentFormatter(100))
    ax.set_xlabel("Share of reviews in the bucket")
    ax.set_title("Late deliveries turn 5-star reviews into 1-star reviews")
    ax.grid(axis="y", visible=False)
    ax.legend(ncol=5, loc="upper center", bbox_to_anchor=(0.5, -0.16), fontsize=8.5)
    save(fig, "02_review_by_delay.png", "results/sql/a05_delay_vs_review__review_by_delay_bucket.csv")


def chart_cohort_heatmap() -> None:
    df = read("a11_cohort_retention__cohort_matrix")
    cols = [f"m{k}_pct" for k in range(1, 7)]           # M0 is 100% by definition -> omitted
    data = df[cols].to_numpy(dtype=float)
    cmap = LinearSegmentedColormap.from_list("blue_seq", BLUE_RAMP)
    cmap.set_bad("#f0efec")
    fig, ax = plt.subplots(figsize=(7.5, 7.2))
    im = ax.imshow(np.ma.masked_invalid(data), cmap=cmap, aspect="auto", vmin=0, vmax=np.nanmax(data))
    for (i, j), v in np.ndenumerate(data):
        if np.isnan(v):
            ax.text(j, i, "–", ha="center", va="center", fontsize=8, color=INK_2)
        else:
            ax.text(j, i, f"{v:.2f}", ha="center", va="center", fontsize=7.5,
                    color="white" if v > 0.45 * np.nanmax(data) else INK)
    ax.set_xticks(range(len(cols)))
    ax.set_xticklabels([f"M{k}" for k in range(1, 7)])
    ax.set_yticks(range(len(df)))
    ax.set_yticklabels([f"{m}  (n={n:,})" for m, n in zip(df["cohort_month"], df["cohort_size"])], fontsize=8)
    ax.set_xlabel("Months after first order")
    ax.set_ylabel("First-order cohort")
    ax.grid(False)
    cbar = fig.colorbar(im, ax=ax, shrink=0.8)
    cbar.set_label("% of cohort ordering again that month", color=INK_2)
    ax.set_title("Fewer than 1 in 100 customers return in any later month")
    save(fig, "03_cohort_heatmap.png", "results/sql/a11_cohort_retention__cohort_matrix.csv (– = not yet observable)")


def chart_repeat_ci() -> None:
    late = read("a12_repeat_and_time_to_second__repeat_by_first_order_late")
    vouch = read("a12_repeat_and_time_to_second__repeat_by_first_order_voucher")
    fig, axes = plt.subplots(1, 2, figsize=(10, 4.3), sharey=True)
    for ax, df, label_col, title in [
        (axes[0], late, "first_order_delivery", "By first-order delivery"),
        (axes[1], vouch, "first_order_payment", "By first-order payment"),
    ]:
        k, n = df["repeat_customers"].to_numpy(), df["eligible_customers"].to_numpy()
        lo, hi = proportion_confint(k, n, alpha=0.05, method="wilson")
        rate = 100 * k / n
        x = np.arange(len(df))
        ax.bar(x, rate, width=0.55, color=BLUE)
        ax.errorbar(x, rate, yerr=[rate - 100 * lo, 100 * hi - rate], fmt="none", ecolor=INK, capsize=6,
                    linewidth=1.2)
        for xi, r, h, kk, nn in zip(x, rate, 100 * hi, k, n):
            ax.text(xi, h + 0.08, f"{r:.2f}%\n({kk:,} / {nn:,})", ha="center", va="bottom", fontsize=8.5)
        ax.set_xticks(x)
        ax.set_xticklabels(df[label_col])
        ax.set_title(title, fontsize=10.5)
        ax.grid(axis="x", visible=False)
    axes[0].set_ylabel("Repeat within 180 days (eligible customers)")
    axes[0].yaxis.set_major_formatter(PercentFormatter(100, decimals=1))
    axes[0].set_ylim(0, 3.6)
    fig.suptitle("180-day repeat rate with 95% confidence intervals (Wilson)", x=0.01, ha="left",
                 fontsize=12, fontweight="bold")
    save(fig, "04_repeat_late_vs_ontime_ci.png", "results/sql/a12_repeat_and_time_to_second__repeat_by_*.csv")


def chart_lead_funnel() -> None:
    df = read("a16_seller_acquisition_funnel__lead_funnel_overall").iloc[::-1].reset_index(drop=True)
    fig, ax = plt.subplots(figsize=(9, 3.8))
    ax.barh(df["stage"], df["sellers"], color=BLUE, height=0.6)
    for i, row in df.iterrows():
        step = "" if pd.isna(row["step_conversion_pct"]) else f"  ·  {row['step_conversion_pct']:.1f}% of previous"
        ax.text(row["sellers"] + 80, i, f"{row['sellers']:,}  ({row['pct_of_mqls']:.2f}% of MQLs){step}",
                va="center", fontsize=8.5)
    ax.set_xlim(0, df["sellers"].max() * 1.65)
    ax.set_xlabel("Leads / sellers")
    ax.xaxis.set_major_formatter(FuncFormatter(lambda v, _p: f"{v:,.0f}"))
    ax.grid(axis="y", visible=False)
    ax.set_title("Seller acquisition: only 2.3% of leads become steady sellers")
    save(fig, "05_lead_funnel.png", "results/sql/a16_seller_acquisition_funnel__lead_funnel_overall.csv")


def chart_pareto() -> None:
    with get_engine().connect() as conn:
        df = pd.read_sql("SELECT gmv_rank, cum_gmv_share FROM mart_pareto_sellers ORDER BY gmv_rank", conn)
    n = len(df)
    x = 100 * df["gmv_rank"] / n
    y = 100 * df["cum_gmv_share"].astype(float)
    k80 = int(df.loc[df["cum_gmv_share"].astype(float) >= 0.8, "gmv_rank"].min())
    fig, ax = plt.subplots(figsize=(7.5, 4.8))
    ax.plot(x, y, color=BLUE, linewidth=2)
    ax.axhline(80, color=INK_2, linewidth=1, linestyle="--")
    ax.plot([100 * k80 / n], [80], marker="o", markersize=8, color=BLUE, markeredgecolor=SURFACE, markeredgewidth=2)
    ax.annotate(f"{k80:,} of {n:,} sellers ({100 * k80 / n:.1f}%)\nmake 80% of GMV",
                xy=(100 * k80 / n, 80), xytext=(100 * k80 / n + 12, 58), fontsize=9,
                arrowprops={"arrowstyle": "-", "color": INK_2, "linewidth": 0.8})
    ax.set_xlim(0, 100)
    ax.set_ylim(0, 102)
    ax.xaxis.set_major_formatter(PercentFormatter(100))
    ax.yaxis.set_major_formatter(PercentFormatter(100))
    ax.set_xlabel("Sellers, ranked by GMV (cumulative share)")
    ax.set_ylabel("Cumulative share of GMV")
    ax.set_title("GMV is concentrated: an 80/20 seller base")
    save(fig, "06_pareto_sellers.png", "MySQL mart_pareto_sellers (same logic as a17_pareto_concentration.sql)")


def chart_lane_heatmap() -> None:
    df = read("a04_delivery_sla_by_lane__lane_sla_region_matrix").set_index("seller_region")
    cols = ["to_north_late_pct", "to_northeast_late_pct", "to_center_west_late_pct",
            "to_southeast_late_pct", "to_south_late_pct"]
    names = ["North", "Northeast", "Center-West", "Southeast", "South"]
    df = df.loc[[r for r in ["Southeast", "South", "Center-West", "Northeast", "North"] if r in df.index]]
    data = df[cols].to_numpy(dtype=float)
    # Colour scale from seller regions with >= 1,000 deliveries; the 25-order North row would
    # otherwise set the maximum (1 late parcel out of 4 = 25%) and wash out real differences.
    vmax = np.nanmax(df.loc[df["delivered_orders"] >= 1000, cols].to_numpy(dtype=float))
    cmap = LinearSegmentedColormap.from_list("blue_seq", BLUE_RAMP)
    cmap.set_bad("#f0efec")
    fig, ax = plt.subplots(figsize=(8, 4.6))
    im = ax.imshow(np.ma.masked_invalid(data), cmap=cmap, aspect="auto", vmin=0, vmax=vmax)
    for (i, j), v in np.ndenumerate(data):
        txt = "–" if np.isnan(v) else f"{v:.1f}%"
        ax.text(j, i, txt, ha="center", va="center", fontsize=9,
                color="white" if (not np.isnan(v) and v > 0.6 * vmax) else INK)
    ax.set_xticks(range(len(names)))
    ax.set_xticklabels(names)
    ax.set_yticks(range(len(df)))
    ax.set_yticklabels([f"{r}  (n={n:,})" for r, n in zip(df.index, df["delivered_orders"])])
    ax.set_xlabel("Customer region")
    ax.set_ylabel("Seller region (valid deliveries)")
    ax.grid(False)
    cbar = fig.colorbar(im, ax=ax, shrink=0.85)
    cbar.set_label(f"Late deliveries (%), scale capped at {vmax:.1f}%", color=INK_2)
    ax.set_title("Late-delivery rate by lane: Northeast-bound parcels are late most often")
    save(fig, "07_lane_late_heatmap.png",
         "results/sql/a04_delivery_sla_by_lane__lane_sla_region_matrix.csv (North sellers: 25 orders)")


def main() -> int:
    CHART_DIR.mkdir(parents=True, exist_ok=True)
    chart_monthly_gmv()
    chart_review_by_delay()
    chart_cohort_heatmap()
    chart_repeat_ci()
    chart_lead_funnel()
    chart_pareto()
    chart_lane_heatmap()
    return 0


if __name__ == "__main__":
    sys.exit(main())
