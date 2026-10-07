# Olist Marketplace Health: Delivery, Discounts & Seller Supply

End-to-end SQL (MySQL) + Python stats + Power BI analysis of a real Brazilian marketplace:
how delivery performance, discounts and seller supply drive reviews, repeat purchases and GMV.

> 🚧 Work in progress. Build plan and acceptance gates: [PROJECT_SPEC.md](PROJECT_SPEC.md).

## Quick start
```bash
make venv          # Python 3.11+ virtualenv
make download      # Kaggle datasets -> data/raw
make db-user       # one-time, as MySQL root
make all           # build the database, run the analysis, stats and Power BI export
```
