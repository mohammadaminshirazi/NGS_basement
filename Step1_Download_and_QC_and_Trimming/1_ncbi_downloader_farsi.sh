#!/bin/bash

# NCBI SRR Accession List Downloader - Enhanced Version
# Usage: ./ncbi_downloader.sh PRJNA390551 /path/to/download/directory

# رنگ‌ها برای خروجی
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
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

# تابع برای استخراج SRR از CSV با Python
extract_srr_with_python() {
    local csv_file="$1"
    local output_file="$2"
    
    python3 -c "
import csv
import sys

try:
    with open('$csv_file', 'r') as f:
        reader = csv.reader(f)
        next(reader)  # Skip header
        srr_list = []
        for row in reader:
            if len(row) > 0 and row[0].startswith('SRR'):
                srr_list.append(row[0].strip())
        
    # Sort and write to file
    srr_list.sort()
    with open('$output_file', 'w') as f:
        for srr in srr_list:
            f.write(srr + '\n')
    
    print(f'Extracted {len(srr_list)} SRR numbers')
except Exception as e:
    print(f'Error: {e}')
    sys.exit(1)
"
}

# بررسی ورودی‌ها
if [ $# -lt 1 ]; then
    print_error "استفاده: $0 <ACCESSION_NUMBER> [DOWNLOAD_PATH]"
    print_info "مثال: $0 PRJNA390551 /home/user/downloads"
    exit 1
fi

ACCESSION=$1
DOWNLOAD_PATH=${2:-$(pwd)}

# بررسی وجود ابزارهای مورد نیاز
for tool in curl python3; do
    if ! command -v $tool &> /dev/null; then
        print_error "$tool نصب نیست. لطفاً نصب کنید."
        exit 1
    fi
done

print_info "شروع دانلود برای پروژه: $ACCESSION"
print_info "مسیر دانلود: $DOWNLOAD_PATH"

# ایجاد دایرکتوری اگر وجود ندارد
mkdir -p "$DOWNLOAD_PATH"

# گام 1: جستجو در SRA database
print_step "جستجو در SRA database..."

SEARCH_URL="https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi"
SEARCH_PARAMS="db=sra&term=$ACCESSION&usehistory=y&retmode=json"

SEARCH_RESPONSE=$(curl -s "$SEARCH_URL?$SEARCH_PARAMS")

if [ -z "$SEARCH_RESPONSE" ]; then
    print_error "خطا در دریافت اطلاعات جستجو"
    exit 1
fi

# بررسی تعداد نتایج
COUNT=$(echo "$SEARCH_RESPONSE" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    print(data['esearchresult']['count'])
except:
    print('0')
")

if [ "$COUNT" = "0" ] || [ -z "$COUNT" ]; then
    print_error "هیچ نتیجه‌ای برای $ACCESSION پیدا نشد"
    print_error "لطفاً شماره accession را بررسی کنید"
    exit 1
fi

print_info "تعداد نتایج پیدا شده: $COUNT"

# استخراج WebEnv و QueryKey
WEBENV=$(echo "$SEARCH_RESPONSE" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    print(data['esearchresult']['webenv'])
except:
    pass
")

QUERYKEY=$(echo "$SEARCH_RESPONSE" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    print(data['esearchresult']['querykey'])
except:
    pass
")

if [ -z "$WEBENV" ] || [ -z "$QUERYKEY" ]; then
    print_error "نتوانست WebEnv یا QueryKey را پیدا کند"
    exit 1
fi

print_info "WebEnv: $WEBENV"
print_info "QueryKey: $QUERYKEY"

# گام 2: دریافت runinfo به صورت CSV
print_step "دریافت اطلاعات runinfo..."

FETCH_URL="https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi"
RUNINFO_PARAMS="db=sra&query_key=$QUERYKEY&WebEnv=$WEBENV&rettype=runinfo&retmode=csv"

OUTPUT_FILE="$DOWNLOAD_PATH/${ACCESSION}_accession_list.txt"
CSV_FILE="$DOWNLOAD_PATH/${ACCESSION}_runinfo.csv"

# دانلود runinfo
print_info "دانلود runinfo..."
curl -s "$FETCH_URL?$RUNINFO_PARAMS" > "$CSV_FILE"

if [ ! -s "$CSV_FILE" ]; then
    print_error "خطا در دریافت runinfo"
    exit 1
fi

# بررسی تعداد خطوط CSV
TOTAL_LINES=$(wc -l < "$CSV_FILE")
DATA_LINES=$((TOTAL_LINES - 1))
print_info "تعداد کل خطوط CSV: $TOTAL_LINES (شامل header)"
print_info "تعداد خطوط داده: $DATA_LINES"

# نمایش header برای debug
print_info "Header CSV:"
head -1 "$CSV_FILE"

# گام 3: استخراج SRR با Python (روش مطمئن)
print_step "استخراج SRR numbers با Python..."

extract_srr_with_python "$CSV_FILE" "$OUTPUT_FILE"

# بررسی نتیجه
if [ -s "$OUTPUT_FILE" ]; then
    LINE_COUNT=$(wc -l < "$OUTPUT_FILE")
    print_info "استخراج موفقیت‌آمیز بود!"
    print_info "فایل ذخیره شد در: $OUTPUT_FILE"
    print_info "تعداد SRR accession ها: $LINE_COUNT"
    
    # مقایسه با تعداد مورد انتظار
    if [ "$LINE_COUNT" -eq "$COUNT" ]; then
        print_info "✅ تعداد SRR ها با انتظار مطابقت دارد ($LINE_COUNT از $COUNT)"
    else
        print_warning "⚠ تعداد SRR ها ($LINE_COUNT) با انتظار ($COUNT) مطابقت ندارد"
        
        # تلاش برای debug
        print_info "بررسی مشکل..."
        echo "نمونه از 5 خط اول CSV (بدون header):"
        tail -n +2 "$CSV_FILE" | head -5
        
        # روش جایگزین با awk
        print_info "تلاش مجدد با awk..."
        tail -n +2 "$CSV_FILE" | awk -F',' '
        {
            if(NF > 0 && $1 ~ /^SRR[0-9]+$/) {
                gsub(/^[ \t]+|[ \t]+$/, "", $1)  # حذف فاصله‌های اضافی
                print $1
            }
        }' | sort -u > "${OUTPUT_FILE}.awk"
        
        AWK_COUNT=$(wc -l < "${OUTPUT_FILE}.awk")
        print_info "نتیجه awk: $AWK_COUNT SRR"
        
        if [ "$AWK_COUNT" -gt "$LINE_COUNT" ]; then
            print_info "✓ روش awk بهتر بود"
            mv "${OUTPUT_FILE}.awk" "$OUTPUT_FILE"
            LINE_COUNT=$AWK_COUNT
        else
            rm -f "${OUTPUT_FILE}.awk"
        fi
    fi
    
    # نمایش نمونه از فایل نهایی
    print_info "نمونه‌ای از SRR های استخراج شده:"
    head -10 "$OUTPUT_FILE" | nl | while read num line; do
        echo "  $num. $line"
    done
    
    if [ $LINE_COUNT -gt 10 ]; then
        echo "  ..."
        echo "  و $(($LINE_COUNT - 10)) مورد دیگر"
    fi
    
    # بررسی فرمت
    FIRST_LINE=$(head -1 "$OUTPUT_FILE")
    if [[ $FIRST_LINE =~ ^SRR[0-9]+$ ]]; then
        print_info "✓ فرمت SRR numbers صحیح است"
    else
        print_warning "⚠ فرمت SRR numbers مشکوک است: $FIRST_LINE"
    fi
else
    print_error "خطا در ایجاد فایل accession list"
    exit 1
fi

# گام 4: ایجاد URL مستقیم Run Selector
RUN_SELECTOR_URL="https://www.ncbi.nlm.nih.gov/Traces/study/?query_key=$QUERYKEY&WebEnv=$WEBENV&o=acc_s%3Aa"
print_info "URL مستقیم Run Selector:"
echo "$RUN_SELECTOR_URL"

# ذخیره URL در فایل جداگانه
echo "$RUN_SELECTOR_URL" > "$DOWNLOAD_PATH/${ACCESSION}_run_selector_url.txt"

# گام 5: ایجاد فایل خلاصه اطلاعات
INFO_FILE="$DOWNLOAD_PATH/${ACCESSION}_info.txt"
{
    echo "NCBI Project Information"
    echo "======================="
    echo "Project Accession: $ACCESSION"
    echo "Expected Count: $COUNT"
    echo "Extracted Count: $LINE_COUNT"
    echo "Download Date: $(date)"
    echo "Run Selector URL: $RUN_SELECTOR_URL"
    echo ""
    echo "Files Created:"
    echo "- ${ACCESSION}_accession_list.txt (SRR numbers)"
    echo "- ${ACCESSION}_runinfo.csv (Raw CSV data)"
    echo "- ${ACCESSION}_run_selector_url.txt (Direct URL)"
    echo "- ${ACCESSION}_info.txt (This file)"
    echo ""
    if [ "$LINE_COUNT" -eq "$COUNT" ]; then
        echo "Status: ✅ SUCCESS - All SRR numbers extracted"
    else
        echo "Status: ⚠ WARNING - Count mismatch (expected: $COUNT, got: $LINE_COUNT)"
    fi
} > "$INFO_FILE"

print_info "فایل اطلاعات ذخیره شد در: $INFO_FILE"
print_info "فایل CSV خام نگه داشته شد در: $CSV_FILE"

if [ "$LINE_COUNT" -eq "$COUNT" ]; then
    print_info "✅ همه کارها با موفقیت انجام شد!"
else
    print_warning "⚠ تعداد نهایی با انتظار مطابقت ندارد، لطفاً فایل CSV را بررسی کنید"
fi
