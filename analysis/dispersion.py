"""Monte Carlo: what a transparent index loses to front-running vs. what Whisper's jitter costs.

Transparent index: the rebalance date and trades are known in advance, so the traded names are
bid up (additions) or pushed down (deletions) before the index trades, then revert. The index
pays that premium on every traded dollar, every time: a one-directional drag.

Whisper: the trades are sealed and the execution time is drawn at random inside
[nominal - 1 day, nominal + 2 days], so nobody can pre-position. There's no premium, but the
fill price is now taken at a random offset from the nominal date. That adds noise whose mean
is zero: sometimes it helps, sometimes it hurts.

Run:  analysis/.venv/bin/python analysis/dispersion.py
Writes analysis/dispersion-{light,dark}.svg and analysis/dispersion-summary.json.
"""

import json
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

OUT = Path(__file__).parent
rng = np.random.default_rng(20261011)

# ---- assumptions (all in one place, quoted in the README) ----
SIMS = 100_000
REBALANCES_PER_YEAR = 4
YEARS = 10
TURNOVER = 0.20  # fraction of NAV traded per rebalance
# Front-running premium on traded notional: ~9 bps run-up + ~13 bps reversal (Dimensional),
# i.e. ~22 bps per traded dollar, varying rebalance to rebalance.
PREMIUM_MEAN_BPS = 22.0
PREMIUM_SD_BPS = 6.0
# Jitter: execution offset uniform over [-1, +2] days around nominal.
JITTER_DAYS = (-1.0, 2.0)
IDIO_VOL_DAILY_BPS = 150.0  # idiosyncratic daily vol of a traded name
NAMES_TRADED = 40  # names traded per rebalance (noise diversifies across them)

N = REBALANCES_PER_YEAR * YEARS


def per_rebalance(sims: int):
    """Return per-rebalance excess return vs. a frictionless fill, in bps of NAV."""
    transparent = -TURNOVER * rng.normal(PREMIUM_MEAN_BPS, PREMIUM_SD_BPS, sims)
    offset = rng.uniform(*JITTER_DAYS, sims)
    basket_sd = IDIO_VOL_DAILY_BPS * np.sqrt(np.abs(offset)) / np.sqrt(NAMES_TRADED)
    whisper = TURNOVER * rng.normal(0.0, 1.0, sims) * basket_sd
    return transparent, whisper


t1, w1 = per_rebalance(SIMS)
# Cumulative paths over 10 years, 5,000 paths each.
P = 5_000
t_paths = np.cumsum(per_rebalance(P * N)[0].reshape(P, N), axis=1)
w_paths = np.cumsum(per_rebalance(P * N)[1].reshape(P, N), axis=1)
x_years = np.arange(1, N + 1) / REBALANCES_PER_YEAR

summary = {
    "assumptions": {
        "rebalancesPerYear": REBALANCES_PER_YEAR,
        "years": YEARS,
        "turnover": TURNOVER,
        "premiumMeanBps": PREMIUM_MEAN_BPS,
        "premiumSdBps": PREMIUM_SD_BPS,
        "jitterDays": JITTER_DAYS,
        "idioVolDailyBps": IDIO_VOL_DAILY_BPS,
        "namesTraded": NAMES_TRADED,
    },
    "perRebalanceBps": {
        "transparent": {"mean": float(t1.mean()), "sd": float(t1.std()), "shareNegative": float((t1 < 0).mean())},
        "whisper": {"mean": float(w1.mean()), "sd": float(w1.std()), "shareNegative": float((w1 < 0).mean())},
    },
    "annualBps": {
        "transparentMean": float(t1.mean() * REBALANCES_PER_YEAR),
        "whisperMean": float(w1.mean() * REBALANCES_PER_YEAR),
    },
    "tenYearCumulativeBps": {
        "transparent": {"median": float(np.median(t_paths[:, -1])), "p5": float(np.percentile(t_paths[:, -1], 5)), "p95": float(np.percentile(t_paths[:, -1], 95))},
        "whisper": {"median": float(np.median(w_paths[:, -1])), "p5": float(np.percentile(w_paths[:, -1], 5)), "p95": float(np.percentile(w_paths[:, -1], 95))},
    },
}
(OUT / "dispersion-summary.json").write_text(json.dumps(summary, indent=2) + "\n")

# ---- chart ----
THEMES = {
    "light": dict(surface="#fcfcfb", text="#0b0b0b", text2="#52514e", grid="#e6e5e0", whisper="#2a78d6", transparent="#eb6834"),
    "dark": dict(surface="#1a1a19", text="#f0efec", text2="#c3c2b7", grid="#33322f", whisper="#3987e5", transparent="#d95926"),
}


def render(mode: str):
    c = THEMES[mode]
    plt.rcParams.update({
        "font.family": "DejaVu Sans", "font.size": 10, "text.color": c["text"],
        "axes.labelcolor": c["text2"], "xtick.color": c["text2"], "ytick.color": c["text2"],
        "axes.edgecolor": c["grid"], "svg.fonttype": "none",
    })
    fig, (a, b) = plt.subplots(1, 2, figsize=(11, 4.2), gridspec_kw={"wspace": 0.28})
    fig.patch.set_facecolor(c["surface"])
    for ax in (a, b):
        ax.set_facecolor(c["surface"])
        ax.grid(axis="y", color=c["grid"], linewidth=0.8)
        ax.set_axisbelow(True)
        for side in ("top", "right"):
            ax.spines[side].set_visible(False)
        ax.tick_params(length=0)

    # Panel A: per-rebalance distributions, step outlines (2px) so neither hides the other.
    bins = np.linspace(-20, 15, 141)
    for data, key, label in ((t1, "transparent", "Transparent index"), (w1, "whisper", "Whisper")):
        h, edges = np.histogram(data, bins=bins, density=True)
        a.stairs(h, edges, color=c[key], linewidth=2)
        a.fill_between(edges[:-1], h, step="post", color=c[key], alpha=0.12, linewidth=0)
    a.axvline(0, color=c["text2"], linewidth=1, linestyle=(0, (2, 2)))
    tm, wm = t1.mean(), w1.mean()
    top = a.get_ylim()[1]
    a.text(-19.5, top * 0.62, f"Transparent:\nalways a cost\nmean {tm:.1f} bps", color=c["text"], fontsize=9, va="center")
    a.text(6.0, top * 0.62, f"Whisper:\ncentered on zero\nmean {abs(wm):.1f} bps", color=c["text"], fontsize=9, va="center")
    a.set_yticks([])
    a.spines["left"].set_visible(False)
    a.set_xlabel("Return vs. a frictionless fill, per rebalance (bps of NAV)")
    a.set_title("Per rebalance", loc="left", color=c["text"], fontsize=11, fontweight="bold")

    # Panel B: cumulative over 10 years: transparent bleed vs. Whisper's zero-centered band.
    t_med = np.median(t_paths, axis=0)
    w_lo, w_med, w_hi = np.percentile(w_paths, [5, 50, 95], axis=0)
    t_lo, t_hi = np.percentile(t_paths, [5, 95], axis=0)
    b.fill_between(x_years, w_lo, w_hi, color=c["whisper"], alpha=0.16, linewidth=0)
    b.fill_between(x_years, t_lo, t_hi, color=c["transparent"], alpha=0.16, linewidth=0)
    b.plot(x_years, w_med, color=c["whisper"], linewidth=2)
    b.plot(x_years, t_med, color=c["transparent"], linewidth=2)
    b.axhline(0, color=c["text2"], linewidth=1, linestyle=(0, (2, 2)))
    b.annotate(f"Transparent {t_med[-1]:.0f} bps", xy=(x_years[-1], t_med[-1]), xytext=(4, 0), textcoords="offset points",
               va="center", color=c["text"], fontsize=9)
    b.annotate(f"Whisper {round(w_med[-1]) or 0:+d} bps\n(90% band {w_lo[-1]:+.0f} to {w_hi[-1]:+.0f})", xy=(x_years[-1], w_med[-1]),
               xytext=(4, 0), textcoords="offset points", va="center", color=c["text"], fontsize=9)
    b.set_xlim(0, YEARS)
    b.set_xlabel("Years")
    b.set_ylabel("Cumulative return vs. frictionless (bps of NAV)")
    b.set_title("Compounded over 10 years (median, 5–95% band)", loc="left", color=c["text"], fontsize=11, fontweight="bold")

    # Legend (two series): shared, top-left of the figure.
    handles = [plt.Line2D([], [], color=c["transparent"], linewidth=2), plt.Line2D([], [], color=c["whisper"], linewidth=2)]
    fig.legend(handles, ["Transparent index (front-run)", "Whisper (sealed, randomized timing)"], loc="upper left",
               bbox_to_anchor=(0.06, 1.04), ncol=2, frameon=False, labelcolor=c["text"])
    fig.savefig(OUT / f"dispersion-{mode}.svg", bbox_inches="tight", facecolor=c["surface"], metadata={"Date": None})
    plt.close(fig)


for mode in THEMES:
    render(mode)

print(json.dumps(summary["perRebalanceBps"], indent=1))
print(json.dumps(summary["tenYearCumulativeBps"], indent=1))
