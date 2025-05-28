#!/bin/bash

# SRA FASTQ Downloader using sra-toolkit
# Usage: ./sra_fastq_downloader.sh <CSV_FILE> [OUTPUT_DIR] [THREADS]

# رنگ‌ها برای خروجی
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# تابع برای نمایش پیام‌های رنگی
print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

print_progress() {
    echo -e "${CYAN}[PROGRESS]${NC} $1"
}

# تابع برای نمایش usage
show_usage() {
    echo "استفاده:"
    echo "  $0 <CSV_FILE> [OUTPUT_DIR] [THREADS]"
    echo ""
    echo "پارامترها:"
    echo "  CSV_FILE    : فایل CSV حاوی اطلاعات SRA (مانند PRJNA390551_runinfo.csv)"
    echo "  OUTPUT_DIR  : دایرکتوری خروجی (پیش‌فرض: ./fastq_downloads)"
    echo "  THREADS     : تعداد thread ها (پیش‌فرض: 4)"
    echo ""
    echo "مثال:"
    echo "  $0 PRJNA390551_runinfo.csv ./data 8"
    echo "  $0 PRJNA390551_accession_list.txt ./fastq_files"
}

# تابع برای بررسی وجود sra-toolkit
check_sra_toolkit() {
    local tools=("fastq-dump" "prefetch" "vdb-validate")
    local missing_tools=()
    
    for tool in "${tools[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            missing_tools+=("$tool")
        fi
    done
    
    if [ ${#missing_tools[@]} -gt 0 ]; then
        print_error "ابزارهای زیر از sra-toolkit یافت نشدند:"
        for tool in "${missing_tools[@]}"; do
            echo "  - $tool"
        done
        echo ""
        print_info "نصب sra-toolkit:"
        echo "  Ubuntu/Debian: sudo apt-get install sra-toolkit"
        echo "  CentOS/RHEL: sudo yum install sra-toolkit"
        echo "  Conda: conda install -c bioconda sra-tools"
        echo "  از سایت NCBI: https://github.com/ncbi/sra-tools"
        return 1
    fi
    
    return 0
}

# تابع برای پیکربندی sra-toolkit
configure_sra_toolkit() {
    local output_dir="$1"
    
    # ایجاد دایرکتوری پیکربندی
    mkdir -p "$HOME/.ncbi"
    
    # پیکربندی vdb-config برای استفاده از دایرکتوری مشخص
    print_info "پیکربندی sra-toolkit..."
    
    # تنظیم repository path
    echo "/repository/user/main/public/cache-enabled = \"true\"" > "$HOME/.ncbi/user-settings.mkfg"
    echo "/repository/user/main/public/cache-location = \"$output_dir/sra_cache\"" >> "$HOME/.ncbi/user-settings.mkfg"
    
    # ایجاد دایرکتوری cache
    mkdir -p "$output_dir/sra_cache"
    
    print_info "sra-toolkit پیکربندی شد"
}

# تابع برای استخراج SRR از فایل
extract_srr_list() {
    local input_file="$1"
    local temp_srr_file="$2"
    
    if [[ "$input_file" == *.csv ]]; then
        # اگر فایل CSV است، SRR از ستون اول استخراج کن
        print_info "استخراج SRR از فایل CSV..."
        tail -n +2 "$input_file" | cut -d',' -f1 | grep '^SRR' | sort > "$temp_srr_file"
    else
        # اگر فایل text است، مستقیماً SRR ها را کپی کن
        print_info "خواندن SRR از فایل متنی..."
        grep '^SRR' "$input_file" | sort > "$temp_srr_file"
    fi
    
    local srr_count=$(wc -l < "$temp_srr_file")
    print_info "تعداد SRR پیدا شده: $srr_count"
    
    if [ "$srr_count" -eq 0 ]; then
        print_error "هیچ SRR معتبری در فایل پیدا نشد"
        return 1
    fi
    
    return 0
}

# تابع برای دانلود یک SRR
download_srr() {
    local srr="$1"
    local output_dir="$2"
    local threads="$3"
    local current="$4"
    local total="$5"
    
    print_progress "[$current/$total] شروع دانلود $srr..."
    
    # ایجاد دایرکتوری برای این SRR
    local srr_dir="$output_dir/$srr"
    mkdir -p "$srr_dir"
    
    # مرحله 1: prefetch برای دانلود سریع‌تر
    print_info "[$current/$total] Prefetch $srr..."
    if prefetch "$srr" -O "$output_dir/sra_cache" 2>/dev/null; then
        print_info "[$current/$total] ✓ Prefetch موفق برای $srr"
    else
        print_warning "[$current/$total] Prefetch ناموفق برای $srr، ادامه با دانلود مستقیم..."
    fi
    
    # مرحله 2: تبدیل به FASTQ
    print_info "[$current/$total] تبدیل $srr به FASTQ..."
    
    # بررسی نوع داده (paired-end یا single-end)
    local fastq_dump_cmd="fastq-dump --split-files --gzip --skip-technical --readids --dumpbase --clip"
    
    if [ "$threads" -gt 1 ]; then
        # استفاده از parallel-fastq-dump اگر موجود باشد
        if command -v parallel-fastq-dump &> /dev/null; then
            fastq_dump_cmd="parallel-fastq-dump --threads $threads --split-files --gzip --skip-technical --readids --dumpbase --clip"
        fi
    fi
    
    # اجرای دستور fastq-dump
    if $fastq_dump_cmd --outdir "$srr_dir" "$srr" 2>"$srr_dir/${srr}_error.log"; then
        print_info "[$current/$total] ✓ دانلود موفق: $srr"
        
        # بررسی فایل‌های ایجاد شده
        local fastq_files=$(ls "$srr_dir"/*.fastq.gz 2>/dev/null | wc -l)
        if [ "$fastq_files" -gt 0 ]; then
            print_info "[$current/$total]   فایل‌های ایجاد شده: $fastq_files"
            ls -lh "$srr_dir"/*.fastq.gz | while read line; do
                echo "    $line"
            done
        fi
        
        # حذف فایل error log اگر خالی باشد
        if [ ! -s "$srr_dir/${srr}_error.log" ]; then
            rm -f "$srr_dir/${srr}_error.log"
        fi
        
        return 0
    else
        print_error "[$current/$total] ✗ خطا در دانلود $srr"
        print_error "[$current/$total]   بررسی فایل log: $srr_dir/${srr}_error.log"
        return 1
    fi
}

# بررسی آرگومان‌ها
if [ $# -lt 1 ]; then
    print_error "تعداد پارامترهای ورودی کافی نیست"
    show_usage
    exit 1
fi

if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    show_usage
    exit 0
fi

# تنظیم پارامترها
INPUT_FILE="$1"
OUTPUT_DIR="${2:-./fastq_downloads}"
THREADS="${3:-4}"

# بررسی ورودی‌ها
if [ ! -f "$INPUT_FILE" ]; then
    print_error "فایل ورودی پیدا نشد: $INPUT_FILE"
    exit 1
fi

if ! [[ "$THREADS" =~ ^[0-9]+$ ]] || [ "$THREADS" -lt 1 ]; then
    print_error "تعداد threads باید عدد مثبت باشد: $THREADS"
    exit 1
fi

# بررسی سیستم و ابزارها
print_step "بررسی سیستم و ابزارها..."

if ! check_sra_toolkit; then
    exit 1
fi

print_info "✓ sra-toolkit یافت شد"
print_info "✓ fastq-dump version: $(fastq-dump --version 2>&1 | head -1)"

# ایجاد دایرکتوری خروجی
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR=$(realpath "$OUTPUT_DIR")

print_info "دایرکتوری خروجی: $OUTPUT_DIR"
print_info "تعداد threads: $THREADS"

# پیکربندی sra-toolkit
configure_sra_toolkit "$OUTPUT_DIR"

# استخراج لیست SRR
TEMP_SRR_FILE="$OUTPUT_DIR/temp_srr_list.txt"
if ! extract_srr_list "$INPUT_FILE" "$TEMP_SRR_FILE"; then
    exit 1
fi

# خواندن تعداد کل SRR ها
TOTAL_SRRS=$(wc -l < "$TEMP_SRR_FILE")

print_step "شروع دانلود $TOTAL_SRRS فایل SRR..."

# متغیرهای آمار
SUCCESS_COUNT=0
FAILED_COUNT=0
START_TIME=$(date +%s)

# ایجاد فایل لاگ
LOG_FILE="$OUTPUT_DIR/download_log.txt"
{
    echo "SRA FASTQ Download Log"
    echo "======================"
    echo "Start Time: $(date)"
    echo "Input File: $INPUT_FILE"
    echo "Output Directory: $OUTPUT_DIR"
    echo "Threads: $THREADS"
    echo "Total SRRs: $TOTAL_SRRS"
    echo ""
} > "$LOG_FILE"

# حلقه دانلود
CURRENT=1
while read -r SRR; do
    if [ ! -z "$SRR" ]; then
        echo "Processing: $SRR ($CURRENT/$TOTAL_SRRS)" >> "$LOG_FILE"
        
        if download_srr "$SRR" "$OUTPUT_DIR" "$THREADS" "$CURRENT" "$TOTAL_SRRS"; then
            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
            echo "SUCCESS: $SRR" >> "$LOG_FILE"
        else
            FAILED_COUNT=$((FAILED_COUNT + 1))
            echo "FAILED: $SRR" >> "$LOG_FILE"
        fi
        
        # نمایش پیشرفت
        PROGRESS=$((CURRENT * 100 / TOTAL_SRRS))
        print_progress "پیشرفت: $PROGRESS% ($CURRENT/$TOTAL_SRRS) - موفق: $SUCCESS_COUNT، ناموفق: $FAILED_COUNT"
        
        CURRENT=$((CURRENT + 1))
    fi
done < "$TEMP_SRR_FILE"

# محاسبه زمان کل
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
HOURS=$((DURATION / 3600))
MINUTES=$(((DURATION % 3600) / 60))
SECONDS=$((DURATION % 60))

# گزارش نهایی
{
    echo ""
    echo "Download Summary"
    echo "==============="
    echo "End Time: $(date)"
    echo "Duration: ${HOURS}h ${MINUTES}m ${SECONDS}s"
    echo "Total SRRs: $TOTAL_SRRS"
    echo "Successful: $SUCCESS_COUNT"
    echo "Failed: $FAILED_COUNT"
    echo ""
} >> "$LOG_FILE"

print_step "خلاصه دانلود:"
print_info "مجموع فایل‌ها: $TOTAL_SRRS"
print_info "موفق: $SUCCESS_COUNT"
print_info "ناموفق: $FAILED_COUNT"
print_info "زمان کل: ${HOURS}h ${MINUTES}m ${SECONDS}s"
print_info "لاگ ذخیره شد در: $LOG_FILE"

# ایجاد خلاصه آمار
STATS_FILE="$OUTPUT_DIR/download_stats.txt"
{
    echo "Download Statistics"
    echo "=================="
    echo "Total Files: $TOTAL_SRRS"
    echo "Successful Downloads: $SUCCESS_COUNT"
    echo "Failed Downloads: $FAILED_COUNT"
    echo "Success Rate: $(( SUCCESS_COUNT * 100 / TOTAL_SRRS ))%"
    echo "Total Duration: ${HOURS}h ${MINUTES}m ${SECONDS}s"
    echo ""
    echo "Directory Structure:"
    find "$OUTPUT_DIR" -name "*.fastq.gz" | wc -l | xargs echo "Total FASTQ files:"
    echo ""
    echo "Disk Usage:"
    du -sh "$OUTPUT_DIR"
} > "$STATS_FILE"

print_info "آمار ذخیره شد در: $STATS_FILE"

# پاکسازی فایل‌های موقت
rm -f "$TEMP_SRR_FILE"

if [ "$FAILED_COUNT" -eq 0 ]; then
    print_info "✅ همه دانلودها موفقیت‌آمیز بودند!"
else
    print_warning "⚠ $FAILED_COUNT دانلود ناموفق بود. جزئیات در فایل لاگ موجود است."
fi

print_info "🎉 دانلود کامل شد!"
