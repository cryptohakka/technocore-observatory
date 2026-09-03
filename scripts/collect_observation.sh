#!/usr/bin/env bash
set -uo pipefail
echo "[cron-start] $(date -u +%FT%TZ) $(basename "$0")"

REPO="$HOME/technocore-observatory"
DATA_DIR="$REPO/data"
BASE="https://technocore.chat"
TODAY=$(date -u +%Y-%m-%d)
OUT="$DATA_DIR/${TODAY}.json"

cd "$REPO" || { echo "[FATAL] repo not found"; exit 1; }

if [ -f "$OUT" ]; then
  echo "[SKIP] 今日(${TODAY})分は既に収集済み: ${OUT}"
  exit 0
fi

echo "[1] /rooms?format=json を取得"
ROOMS_JSON=$(curl -sS -m 20 "${BASE}/rooms?format=json")
if [ -z "$ROOMS_JSON" ]; then
  echo "[FATAL] 取得失敗(空レスポンス)"
  exit 1
fi

echo "[2] 必要な値を抽出してスナップショットを作成"
python3 -c "
import json, sys
from datetime import datetime, timezone

d = json.loads(sys.argv[1])
today = sys.argv[2]

snapshot = {
    'date': today,
    'collected_at': datetime.now(timezone.utc).isoformat(),
    'rooms': {'total': d['total'], 'capacity': d['capacity'], 'headroom': d['capacity'] - d['total']},
    'notes': {
        'total': d['notes']['total'],
        'capacity': d['notes']['capacity'],
        'capacity_per_namespace': d['notes']['capacity_per_namespace'],
        'headroom': d['notes']['capacity'] - d['notes']['total'],
    },
    'bytes': {'rooms_total': d['bytes'], 'rooms_capacity': d['bytes_capacity']},
    'engagement': d['engagement'],
    'top_rooms_by_bytes': sorted(
        [{'room': r['room'], 'bytes': r.get('bytes', 0), 'nick_diversity': r.get('nick_diversity'), 'zero_response_share': r.get('zero_response_share')} for r in d['rooms']],
        key=lambda r: r['bytes'], reverse=True
    )[:10],
}
json.dump(snapshot, open('$OUT', 'w'), indent=2)
print('written: $OUT')
" "$ROOMS_JSON" "$TODAY"


echo "[2b] docs/data/ を更新(Pages用の集計・最新スナップショット)"
mkdir -p "$REPO/docs/data"
python3 - << 'INNER_PYEOF'
import json, glob, os
rows = []
for f in sorted(glob.glob("data/*.json")):
    d = json.load(open(f))
    rows.append({
        "date": d["date"],
        "rooms_total": d["rooms"]["total"],
        "rooms_capacity": d["rooms"]["capacity"],
        "notes_total": d["notes"]["total"],
        "notes_capacity": d["notes"]["capacity"],
        "note_to_message_ratio": d["engagement"]["windowed_note_to_message_ratio"],
        "nick_diversity": d["engagement"]["nick_diversity"],
        "zero_response_share": d["engagement"]["zero_response_share"],
        "windowed_messages": d["engagement"]["windowed_messages"],
    })
json.dump(rows, open("docs/data/timeseries.json", "w"), indent=2)
if rows:
    latest_file = sorted(glob.glob("data/*.json"))[-1]
    json.dump(json.load(open(latest_file)), open("docs/data/latest.json", "w"), indent=2)
INNER_PYEOF

echo "[3] git add/commit/push"
cd "$REPO"
git add "data/${TODAY}.json" docs/data/timeseries.json docs/data/latest.json
if git diff --cached --quiet; then
  echo "[SKIP] 差分なし(既にcommit済み)"
else
  git -c user.name="cryptohakka" -c user.email="cryptohakka@protonmail.com" \
    commit -m "data: observation snapshot ${TODAY}"
  git push origin main
  echo "[OK] push完了"
fi
