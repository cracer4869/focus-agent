#!/usr/bin/env bash
# Focus 恢复：从 focus-backup.sh 的产物恢复数据库 / data / 配置 / 运维文件 / 源码仓库。
#
#   ./focus-restore.sh --list                  列出可用备份（时间戳）
#   ./focus-restore.sh --db   <ts>             只恢复 PostgreSQL（artex 库）
#   ./focus-restore.sh --data <ts>             只恢复 data/（tasks transcripts sessions traffic stage tunnels）
#   ./focus-restore.sh --all  <ts>             恢复 DB + data + config.json + 运维文件
#   ./focus-restore.sh --repo <ts>             从 git bundle 恢复源码仓库到同级目录
#   ./focus-restore.sh --all <ts> --yes        跳过确认（自动化场景）
#
# 说明：
#   - 恢复是破坏性动作：--db 会 DROP 并重建 artex 库，--data 会先备份现有 data/ 再覆盖。
#   - 服务在跑会先 stop（focus.sh stop），恢复完成后不会自动拉起，需要你确认后 focus.sh start。
#   - 备份产物含明文口令（llm_profiles.api_key、管理员密码哈希、artex.env），
#     目录本身就是 700/600，恢复后不要往外拷。
set -uo pipefail
cd "$(cd "$(dirname "$0")" && pwd)"

PGBIN=/usr/lib/postgresql/18/bin
DEST="$HOME/.local/share/focus-agent/backups"
PGDATA="$HOME/.local/share/focus-agent/pgdata"
DB=artex

ok(){   printf '\033[32m[+]\033[0m %s\n' "$*"; }
info(){ printf '\033[36m[*]\033[0m %s\n' "$*"; }
warn(){ printf '\033[33m[!]\033[0m %s\n' "$*"; }
die(){  printf '\033[31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

# 库口令从 config.json 读，避免在本脚本里再存一份明文。
db_password(){
  if [ -f config.json ] && command -v jq >/dev/null 2>&1; then
    jq -r '.database.password // empty' config.json 2>/dev/null
  fi
}

pg_ready(){ "$PGBIN/pg_isready" -h 127.0.0.1 -p 5432 -q; }

list_backups(){
  [ -d "$DEST" ] || die "备份目录不存在：$DEST"
  info "备份目录：$DEST"
  local f ts found=0
  for f in $(ls -1t "$DEST"/artex-*.dump 2>/dev/null); do
    ts="${f##*/artex-}"; ts="${ts%.dump}"
    local db data ops repo
    db=$(du -h "$f" 2>/dev/null | cut -f1)
    [ -f "$f.data.tar.gz" ] && data=$(du -h "$f.data.tar.gz" | cut -f1) || data="-"
    [ -d "$DEST/ops-$ts" ] && ops=$(ls -1 "$DEST/ops-$ts" | wc -l) || ops=0
    [ -f "$DEST/repo-$ts.bundle" ] && repo=$(du -h "$DEST/repo-$ts.bundle" | cut -f1) || repo="-"
    printf '  %-20s db=%-6s data=%-6s ops=%-3s repo=%s\n' "$ts" "$db" "$data" "$ops" "$repo"
    found=1
  done
  [ "$found" = 1 ] || warn "没有任何备份产物（先跑 ./focus-backup.sh）"
}

confirm(){
  [ "${YES:-0}" = 1 ] && return 0
  printf '\033[33m[?]\033[0m 即将执行：%s\n    输入 yes 继续：' "$1"
  local ans; read -r ans
  [ "$ans" = "yes" ] || die "已取消"
}

stop_service(){
  if pgrep -x artex >/dev/null 2>&1 || pg_ready; then
    info "停止 Focus 与 PostgreSQL"
    ./focus.sh stop >/dev/null 2>&1 || true
    sleep 1
  fi
  pgrep -x artex >/dev/null 2>&1 && die "artex 仍在运行，先手动 ./focus.sh stop"
  return 0
}

restore_db(){
  local ts="$1" dump="$DEST/artex-$1.dump"
  [ -f "$dump" ] || die "找不到 dump：$dump"
  "$PGBIN/pg_restore" --list "$dump" >/dev/null 2>&1 || die "dump 损坏（pg_restore --list 读不出）：$dump"
  confirm "DROP 并重建 $DB 库，从 $dump 恢复"
  stop_service
  info "启动 PostgreSQL"
  ./focus.sh start >/dev/null 2>&1 || true
  # focus.sh start 会把 artex 一起拉起来；这里立刻停掉 app，避免恢复期间有写请求。
  pkill -x artex 2>/dev/null; sleep 1
  pg_ready || die "PostgreSQL 未就绪"
  local pw; pw=$(db_password)
  export PGPASSWORD="$pw"
  info "重建数据库 $DB"
  "$PGBIN/dropdb"   -h 127.0.0.1 -p 5432 -U artex --if-exists "$DB" || die "dropdb 失败"
  "$PGBIN/createdb" -h 127.0.0.1 -p 5432 -U artex -O artex "$DB"      || die "createdb 失败"
  info "恢复数据"
  "$PGBIN/pg_restore" -h 127.0.0.1 -p 5432 -U artex -d "$DB" --no-owner --no-privileges "$dump" \
    || die "pg_restore 失败（库可能处于半恢复状态，可重跑本命令）"
  local tables
  tables=$("$PGBIN/psql" -h 127.0.0.1 -p 5432 -U artex -d "$DB" -tAc \
    "select count(*) from pg_tables where schemaname='public'")
  ok "数据库已恢复：$DB（public 表 $tables 张）"
  unset PGPASSWORD
}

restore_data(){
  local ts="$1" tgz="$DEST/artex-$1.dump.data.tar.gz"
  [ -f "$tgz" ] || die "找不到 data 包：$tgz"
  confirm "把 $tgz 解包覆盖 data/（现有 data 会先另存为 data.pre-restore-<ts>）"
  stop_service
  if [ -d data ]; then
    local keep="data.pre-restore-$(date +%Y%m%d-%H%M%S)"
    mv data "$keep" && ok "现有 data/ 已移到 $keep"
  fi
  mkdir -p data
  tar -xzf "$tgz" -C data || die "解包失败"
  chmod 700 data 2>/dev/null || true
  for d in tasks transcripts sessions traffic stage tunnels; do
    [ -d "data/$d" ] && chmod 700 "data/$d" 2>/dev/null
  done
  ok "data 已恢复"
}

restore_config(){
  local ts="$1" cfg="$DEST/config-$1.json"
  if [ -f "$cfg" ]; then
    install -m600 "$cfg" config.json && ok "config.json 已恢复"
  else
    warn "没有该时间戳的 config 备份，跳过"
  fi
  local ops="$DEST/ops-$ts"
  if [ -d "$ops" ]; then
    local n=0 f mode
    for f in "$ops"/*; do
      [ -f "$f" ] || continue
      mode=600
      case "$(basename "$f")" in *.sh) mode=700 ;; esac
      # 脚本自身在运行，直接覆盖会踩到正在执行的 fd；先落临时文件再原子替换。
      install -m"$mode" "$f" "$PWD/.restore-tmp-$$" && mv -f "$PWD/.restore-tmp-$$" "$PWD/$(basename "$f")"
      n=$((n+1))
    done
    ok "运维文件已恢复 $n 个（来自 $ops）"
  else
    warn "没有该时间戳的运维文件备份，跳过"
  fi
}

restore_repo(){
  local ts="$1" bundle="$DEST/repo-$1.bundle"
  [ -f "$bundle" ] || die "找不到 repo bundle：$bundle"
  local target="$PWD.pre-restore-$(date +%Y%m%d-%H%M%S)"
  confirm "从 $bundle 检出完整仓库到 $target（现有目录不动）"
  git clone --quiet "$bundle" "$target" || die "git clone 失败（bundle 损坏或 git 版本过低）"
  ok "源码已恢复：$target"
  info "校验：cd $target && git log --oneline -1"
}

# ── 参数解析 ──────────────────────────────────────────────────
ACTION=""; TS=""; YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --list) list_backups; exit 0 ;;
    --db|--data|--all|--repo) ACTION="${1#--}"; shift; TS="${1:-}"; shift ;;
    --yes|-y) YES=1; shift ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "未知参数：$1（--help 看用法）" ;;
  esac
done

[ -n "$ACTION" ] || { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
[ -n "$TS" ] || TS="$(ls -1t "$DEST"/artex-*.dump 2>/dev/null | head -1 | sed -E 's#.*/artex-(.*)\.dump#\1#')"
[ -n "$TS" ] || die "没有可用备份，先跑 ./focus-backup.sh"

case "$ACTION" in
  db)   restore_db "$TS" ;;
  data) restore_data "$TS" ;;
  repo) restore_repo "$TS" ;;
  all)
    [ -f "$DEST/artex-$TS.dump" ] || die "找不到 dump：$DEST/artex-$TS.dump"
    confirm "完整恢复 $TS：DB + data + config + 运维文件"
    restore_db "$TS"
    stop_service
    ./focus.sh start >/dev/null 2>&1 || true
    pkill -x artex 2>/dev/null; sleep 1
    restore_data "$TS"
    restore_config "$TS"
    ok "恢复完成。确认无误后执行：./focus.sh start"
    ;;
esac
