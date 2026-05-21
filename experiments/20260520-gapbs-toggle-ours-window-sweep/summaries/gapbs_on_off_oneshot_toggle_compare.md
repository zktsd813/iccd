# GAPBS on/off vs one-shot ours vs toggle ours

Values are GAPBS `Average Time` in seconds, lower is better.

- `off`: #178 node-capacity off baseline used in the previous comparison.
- `on`: #179 migration-on baseline.
- `one-shot`: #179 one-shot local-util `ours`; PR has #179 5s only, BC has #179 5/10/20.
- `toggle`: #179 controller that re-enables migration after 2 non-matching windows.

## PR

| cap | window | off | on | one-shot | one-shot off s | toggle | toggle off->on s |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| 8g | 5 | 18.87299 | 45.41178 | 20.18425 | 45.022 | 50.36476 | 45.027 -> 60.032 |
| 8g | 10 | 18.87299 | 45.41178 | n/a | n/a | 34.85731 | 50.013 -> 80.016 |
| 8g | 20 | 18.87299 | 45.41178 | n/a | n/a | 33.86487 | 80.010 -> 140.013 |
| 16g | 5 | 19.06677 | 44.05163 | 19.77788 | 35.016 | 42.13903 | 35.017 -> 50.022 |
| 16g | 10 | 19.06677 | 44.05163 | n/a | n/a | 30.10791 | 50.009 -> 80.012 |
| 16g | 20 | 19.06677 | 44.05163 | n/a | n/a | 29.17429 | 80.009 -> 140.013 |

## BC

| cap | window | off | on | one-shot | one-shot off s | toggle | toggle off->on s |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| 8g | 5 | 16.39678 | 52.61184 | 41.69187 | 70.027 | 50.62334 | 65.026 -> 80.032 |
| 8g | 10 | 16.39678 | 52.61184 | 36.72230 | 90.013 | 50.74007 | 90.015 -> 130.018 |
| 8g | 20 | 16.39678 | 52.61184 | 41.60252 | 140.009 | 49.08597 | 140.010 -> 200.014 |
| 16g | 5 | 49.38733 | 19.98134 | 14.17649 | 45.020 | 35.36535 | 65.022 -> 85.026 |
| 16g | 10 | 49.38733 | 19.98134 | 23.23782 | 90.012 | 18.59924 | 80.013 -> 110.017 |
| 16g | 20 | 49.38733 | 19.98134 | 25.90131 | 100.006 | 19.65504 | 80.006 -> 140.009 |
