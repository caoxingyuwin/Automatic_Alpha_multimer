#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# usuage
###############################################################################
usage () {
  cat <<EOF
Usage:
  $0 -i <input_fasta_or_dir> -o <archive_output_root> [options]

Required:
  -i    Input fasta file OR directory containing fasta files
  -o    Output archive root directory (recommended: network disk)

Optional:
  --local-root   Local temp root (default: /mnt/nvme)
  --db           ColabFold DB path (default: /mnt/nvme/colabfold_db/)
  --mmseqs       mmseqs binary path
                 (default: /home/ubuntu/localcolabfold/localcolabfold/conda/envs/colabfold/bin/mmseqs)
  --threads      Threads for colabfold_search (default: 15)
  --gpu          GPU id for colabfold_search (default: 1)

  --model-type   Model type for colabfold_batch (default: alphafold2_multimer_v3)
  --num-models   Number of models (default: 5)
  --num-recycles Number of recycles (default: 3)
  --pair-mode    Pair mode (default: unpaired_paired)
  --pair-strategy Pair strategy (default: greedy)
  --use-templates  Use templates in prediction (default: on)
  --no-templates   Disable templates

Examples:
  # Run all fasta files in a directory
  $0 -i /mnt/nvme/complexs -o /home/Ubuntu/archive

  # Run one fasta file
  $0 -i /mnt/nvme/complexs/complex1.fasta -o /home/Ubuntu/archive

  # Customize local temp root and gpu
  $0 -i ./complexs -o /home/Ubuntu/archive --local-root /mnt/nvme --gpu 0 --threads 20
EOF
  exit 1
}

###############################################################################
# 默认参数
###############################################################################
INPUT_PATH=""
ARCHIVE_ROOT=""

LOCAL_ROOT="/mnt/nvme"
COLABFOLD_DB="/mnt/nvme/colabfold_db/"
MMSEQS_BIN="/home/ubuntu/localcolabfold/localcolabfold/conda/envs/colabfold/bin/mmseqs"

SEARCH_THREADS="15"
SEARCH_GPU="1"

MODEL_TYPE="alphafold2_multimer_v3"
NUM_MODELS="5"
NUM_RECYCLES="3"
PAIR_MODE="unpaired_paired"
PAIR_STRATEGY="greedy"
USE_TEMPLATES="1"   # 1=on, 0=off

###############################################################################
# 解析参数
###############################################################################
while [[ $# -gt 0 ]]; do
  case "$1" in
    -i) INPUT_PATH="$2"; shift 2 ;;
    -o) ARCHIVE_ROOT="$2"; shift 2 ;;
    --local-root) LOCAL_ROOT="$2"; shift 2 ;;
    --db) COLABFOLD_DB="$2"; shift 2 ;;
    --mmseqs) MMSEQS_BIN="$2"; shift 2 ;;
    --threads) SEARCH_THREADS="$2"; shift 2 ;;
    --gpu) SEARCH_GPU="$2"; shift 2 ;;

    --model-type) MODEL_TYPE="$2"; shift 2 ;;
    --num-models) NUM_MODELS="$2"; shift 2 ;;
    --num-recycles) NUM_RECYCLES="$2"; shift 2 ;;
    --pair-mode) PAIR_MODE="$2"; shift 2 ;;
    --pair-strategy) PAIR_STRATEGY="$2"; shift 2 ;;

    --use-templates) USE_TEMPLATES="1"; shift 1 ;;
    --no-templates) USE_TEMPLATES="0"; shift 1 ;;

    -h|--help) usage ;;
    *) echo "[ERROR] Unknown argument: $1"; usage ;;
  esac
done

if [[ -z "$INPUT_PATH" || -z "$ARCHIVE_ROOT" ]]; then
  echo "[ERROR] -i and -o are required"
  usage
fi

###############################################################################
# 本地工作目录（临时）
###############################################################################
MSA_WORK_ROOT="$LOCAL_ROOT/msas_work"
PRED_WORK_ROOT="$LOCAL_ROOT/predictions_work"

###############################################################################
# 工具函数
###############################################################################
need_cmd () { command -v "$1" >/dev/null 2>&1 || { echo "[ERROR] Missing command: $1" >&2; exit 1; }; }

log () { echo "[$(date '+%F %T')] $*"; }

# 复制文件 + MD5 校验一致后删除源文件
safe_archive_file_md5 () {
  local src="$1"
  local dst="$2"  # 目标完整路径（含文件名）

  if [[ ! -s "$src" ]]; then
    echo "[ERROR] Source missing/empty: $src" >&2
    return 1
  fi

  mkdir -p "$(dirname "$dst")"

  # 复制（更稳）
  rsync -a --inplace "$src" "$dst"

  # MD5 校验
  local md1 md2
  md1="$(md5sum "$src" | awk '{print $1}')"
  md2="$(md5sum "$dst" | awk '{print $1}')"

  if [[ "$md1" != "$md2" ]]; then
    echo "[ERROR] MD5 mismatch: $src -> $dst ($md1 vs $md2)" >&2
    return 1
  fi

  # 校验成功才删除源
  rm -f "$src"
}

# 归档目录到目标目录，成功后删除源目录
safe_archive_dir_rsync () {
  local src_dir="$1"
  local dst_dir="$2"

  if [[ ! -d "$src_dir" ]]; then
    echo "[ERROR] Source dir not found: $src_dir" >&2
    return 1
  fi

  mkdir -p "$dst_dir"
  rsync -a --delete "$src_dir/" "$dst_dir/"
  rm -rf "$src_dir"
}

###############################################################################
# 环境检查
###############################################################################
need_cmd colabfold_search
need_cmd colabfold_batch
need_cmd rsync
need_cmd md5sum
need_cmd find
need_cmd ls
need_cmd head

if [[ ! -x "$MMSEQS_BIN" ]]; then
  echo "[ERROR] mmseqs not executable: $MMSEQS_BIN" >&2
  exit 1
fi
if [[ ! -d "$COLABFOLD_DB" ]]; then
  echo "[ERROR] DB dir not found: $COLABFOLD_DB" >&2
  exit 1
fi

mkdir -p "$MSA_WORK_ROOT" "$PRED_WORK_ROOT" "$ARCHIVE_ROOT"

###############################################################################
# 收集输入 fasta：支持 单文件 or 目录
###############################################################################
INPUT_FASTAS=()

if [[ -d "$INPUT_PATH" ]]; then
  log "[INFO] Input is a directory: $INPUT_PATH"
  while IFS= read -r -d '' f; do
    INPUT_FASTAS+=( "$f" )
  done < <(
    find "$INPUT_PATH" -maxdepth 1 -type f \
      \( -name "*.fasta" -o -name "*.fa" -o -name "*.faa" -o -name "*.fastaa" \) \
      -print0
  )
elif [[ -f "$INPUT_PATH" ]]; then
  log "[INFO] Input is a file: $INPUT_PATH"
  INPUT_FASTAS+=( "$INPUT_PATH" )
else
  echo "[ERROR] Input path not found: $INPUT_PATH" >&2
  exit 1
fi

if [[ ${#INPUT_FASTAS[@]} -eq 0 ]]; then
  echo "[ERROR] No fasta files found in input: $INPUT_PATH" >&2
  exit 1
fi

log "[INFO] Found ${#INPUT_FASTAS[@]} fasta file(s)"
log "[INFO] Local temp root : $LOCAL_ROOT"
log "[INFO] Archive root    : $ARCHIVE_ROOT"
log "[INFO] MSA work root   : $MSA_WORK_ROOT (will be deleted per complex)"
log "[INFO] Pred work root  : $PRED_WORK_ROOT (will be archived then deleted per complex)"

###############################################################################
# 主循环
###############################################################################
for fasta in "${INPUT_FASTAS[@]}"; do
  fname="$(basename "$fasta")"
  base="${fname%.*}"

  # 网络盘：每个complex一个目录
  net_complex_dir="$ARCHIVE_ROOT/$base"
  net_msa_dir="$net_complex_dir/msa"
  net_pred_dir="$net_complex_dir/predictions"
  net_log_dir="$net_complex_dir/logs"
  mkdir -p "$net_msa_dir" "$net_pred_dir" "$net_log_dir"

  # 日志（写到网络盘）
  search_log="$net_log_dir/search.log"
  predict_log="$net_log_dir/predict.log"
  archive_log="$net_log_dir/archive.log"

  # 本地工作目录
  msa_dir="$MSA_WORK_ROOT/$base"
  pred_dir="$PRED_WORK_ROOT/$base"
  mkdir -p "$msa_dir" "$pred_dir"

  echo "============================================================"
  log "[INFO] Complex: $base"
  log "[INFO] FASTA  : $fasta"
  log "[INFO] NETDIR : $net_complex_dir"

  # 断点续跑：网络盘已有 a3m 且 predictions 有结果就跳过
  net_a3m="$net_msa_dir/$base.a3m"
  if [[ -s "$net_a3m" ]] && [[ -d "$net_pred_dir" ]] && \
     (compgen -G "$net_pred_dir/*.pdb" >/dev/null || compgen -G "$net_pred_dir/*ranking*.json" >/dev/null); then
    log "[INFO] Already archived (a3m + predictions). Skip."
    rm -rf "$msa_dir" "$pred_dir" || true
    continue
  fi

  ###########################################################################
  # 1) 生成 MSA（本地）
  ###########################################################################
  local_a3m="$msa_dir/$base.a3m"

  if [[ -s "$local_a3m" ]]; then
    log "[INFO] Local a3m exists, skip search: $local_a3m"
  else
    log "[INFO] Running colabfold_search ..."
    (
      set -x
      colabfold_search \
        --mmseqs "$MMSEQS_BIN" \
        "$fasta" "$COLABFOLD_DB" "$msa_dir" \
        --gpu "$SEARCH_GPU" --threads "$SEARCH_THREADS"
    ) 2>&1 | tee -a "$search_log"

    # 统一 a3m 命名：如果生成的不是 base.a3m，选最新的复制过来
    if compgen -G "$msa_dir/*.a3m" >/dev/null; then
      newest_a3m="$(ls -1t "$msa_dir"/*.a3m | head -n 1)"
      if [[ "$newest_a3m" != "$local_a3m" ]]; then
        cp -f "$newest_a3m" "$local_a3m"
      fi
    fi

    if [[ ! -s "$local_a3m" ]]; then
      log "[ERROR] No valid a3m produced for $base in $msa_dir"
      exit 1
    fi
  fi

  ###########################################################################
  # 2) 预测（本地）
  ###########################################################################
  if compgen -G "$pred_dir/*.pdb" >/dev/null || compgen -G "$pred_dir/*ranking*.json" >/dev/null; then
    log "[INFO] Local prediction exists, skip predict: $pred_dir"
  else
    log "[INFO] Running colabfold_batch (multimer v3) ..."
    (
      set -x
      args=(
        "$local_a3m" "$pred_dir"
        --model-type "$MODEL_TYPE"
        --num-models "$NUM_MODELS"
        --num-recycles "$NUM_RECYCLES"
        --pair-mode "$PAIR_MODE"
        --pair-strategy "$PAIR_STRATEGY"
      )
      if [[ "$USE_TEMPLATES" == "1" ]]; then
        args+=( --use-templates )
      fi
      colabfold_batch "${args[@]}"
    ) 2>&1 | tee -a "$predict_log"
  fi

  ###########################################################################
  # 3) 归档 + 清理
  ###########################################################################
  log "[INFO] Archiving a3m with MD5 -> $net_a3m"
  (
    safe_archive_file_md5 "$local_a3m" "$net_a3m"
    echo "Archived a3m to: $net_a3m"
  ) 2>&1 | tee -a "$archive_log"

  log "[INFO] Deleting local MSA work dir: $msa_dir"
  rm -rf "$msa_dir"

  log "[INFO] Archiving predictions dir -> $net_pred_dir"
  (
    safe_archive_dir_rsync "$pred_dir" "$net_pred_dir"
    echo "Archived predictions to: $net_pred_dir"
  ) 2>&1 | tee -a "$archive_log"

  log "[INFO] Done: $base"
done

echo "============================================================"
log "[INFO] All complexes finished."
