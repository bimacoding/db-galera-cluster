#!/usr/bin/env bash
# ==============================================================
# release.sh — Satu perintah: build CI → download binary → GitHub Release
#
# Prasyarat:
#   brew install gh
#   gh auth login
#
# Contoh:
#   ./tools/release.sh v0.1.0              # trigger CI, tunggu, release
#   ./tools/release.sh v0.1.0 --latest     # pakai artifact CI terakhir (tanpa build baru)
#   ./tools/release.sh v0.1.0 --dry-run    # simulasi tanpa tag/release
# ==============================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${SCRIPT_DIR}/.."
REPO_ROOT="$(git -C "${SRC}" rev-parse --show-toplevel 2>/dev/null || true)"

WORKFLOW_FILE="build-dist.yml"
WORKFLOW_NAME="Build galera-cluster-dist"
DEFAULT_BRANCH="master"

PLATFORMS=(
    darwin-aarch64
    darwin-x86_64
    linux-x86_64
    linux-aarch64
    windows-x86_64
)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
log()  { echo -e "${BLUE}[release]${NC} $*"; }
ok()   { echo -e "${GREEN}[ok]${NC}      $*"; }
warn() { echo -e "${YELLOW}[warn]${NC}    $*"; }
err()  { echo -e "${RED}[err]${NC}     $*" >&2; }

VERSION=""
USE_LATEST=0
DRY_RUN=0
SKIP_TAG_PUSH=0
NOTES_FILE=""
BUMP_CARGO=0

usage() {
    cat <<'EOF'
release.sh — Buat GitHub Release dengan semua binary dari GitHub Actions

Usage:
  ./tools/release.sh <versi> [opsi]

Versi:
  v0.1.0          Wajib diawali "v" (semver)

Opsi:
  --latest        Pakai workflow run sukses terakhir (tanpa trigger build baru)
  --dry-run       Simulasi: tidak buat tag / release
  --skip-tag      Upload release saja (tag sudah ada di remote)
  --notes FILE    Catatan release dari file markdown
  --bump-cargo    Sync versi ke mariadb-galera-cluster-fix/tui/Cargo.toml
  -h, --help      Bantuan

Alur default (tanpa --latest):
  1. Trigger GitHub Actions "Build galera-cluster-dist"
  2. Tunggu build 5 platform selesai
  3. Download galera-cluster-dist.zip + binary per platform
  4. Buat git tag + push
  5. Publish GitHub Release + upload semua asset

Prasyarat:
  gh auth login
  git push akses ke origin

Contoh:
  cd mariadb-galera-cluster-fix
  ./tools/release.sh v0.1.0
  ./tools/release.sh v0.2.0 --latest --notes RELEASE_NOTES.md
EOF
}

die() { err "$*"; exit 1; }

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Perintah '$1' tidak ditemukan. Install dulu."
}

normalize_version() {
    local v="$1"
    [[ "$v" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?$ ]] || die "Format versi tidak valid: '$v' (contoh: v0.1.0)"
    echo "$v"
}

parse_args() {
    [[ $# -gt 0 ]] || { usage; exit 1; }

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                usage
                exit 0
                ;;
            --latest)
                USE_LATEST=1
                ;;
            --dry-run)
                DRY_RUN=1
                ;;
            --skip-tag)
                SKIP_TAG_PUSH=1
                ;;
            --bump-cargo)
                BUMP_CARGO=1
                ;;
            --notes)
                shift
                [[ $# -gt 0 ]] || die "--notes membutuhkan path file"
                NOTES_FILE="$1"
                [[ -f "$NOTES_FILE" ]] || die "File notes tidak ditemukan: $NOTES_FILE"
                ;;
            v*)
                [[ -z "$VERSION" ]] || die "Versi sudah di-set: $VERSION"
                VERSION="$(normalize_version "$1")"
                ;;
            *)
                die "Argumen tidak dikenal: $1 (pakai --help)"
                ;;
        esac
        shift
    done

    [[ -n "$VERSION" ]] || die "Versi wajib diisi (contoh: v0.1.0)"
}

preflight() {
    [[ -n "$REPO_ROOT" ]] || die "Bukan folder git. Jalankan dari repo Ansible-mysql-galera-cluster."
    cd "$REPO_ROOT"

    need_cmd git
    need_cmd gh
    need_cmd unzip
    need_cmd zip

    gh auth status >/dev/null 2>&1 || die "Belum login GitHub CLI. Jalankan: gh auth login"

    if [[ -n "$(git status --porcelain)" ]]; then
        warn "Working tree belum bersih:"
        git status --short
        warn "Disarankan commit & push dulu sebelum release."
    fi

    if git rev-parse "$VERSION" >/dev/null 2>&1; then
        die "Tag $VERSION sudah ada lokal. Pilih versi lain atau hapus tag lama."
    fi

    if gh release view "$VERSION" >/dev/null 2>&1; then
        die "Release $VERSION sudah ada di GitHub."
    fi
}

detect_branch() {
    local branch
    branch="$(git branch --show-current 2>/dev/null || true)"
    if [[ -z "$branch" ]]; then
        branch="$DEFAULT_BRANCH"
    fi
    echo "$branch"
}

bump_cargo_version() {
    local cargo_toml="${SRC}/tui/Cargo.toml"
    [[ -f "$cargo_toml" ]] || return 0

    local semver="${VERSION#v}"
    if [[ "$DRY_RUN" -eq 1 ]]; then
        log "[dry-run] Cargo.toml → version = \"$semver\""
        return 0
    fi

    if sed -i.bak "s/^version = \".*\"/version = \"${semver}\"/" "$cargo_toml" 2>/dev/null; then
        rm -f "${cargo_toml}.bak"
        ok "Cargo.toml version → ${semver}"
    elif sed -i '' "s/^version = \".*\"/version = \"${semver}\"/" "$cargo_toml"; then
        ok "Cargo.toml version → ${semver}"
    else
        warn "Gagal update Cargo.toml (abaikan jika tidak perlu)"
    fi
}

trigger_workflow() {
    local branch="$1"
    log "Trigger workflow: ${WORKFLOW_NAME} (ref: ${branch})"
    gh workflow run "$WORKFLOW_FILE" --ref "$branch" \
        || die "Gagal trigger workflow. Pastikan file .github/workflows/${WORKFLOW_FILE} sudah di-push."

    log "Menunggu workflow run muncul..."
    local run_id=""
    local i
    for i in $(seq 1 30); do
        sleep 2
        run_id="$(gh run list --workflow="$WORKFLOW_FILE" --branch="$branch" --limit 1 --json databaseId,status --jq '.[0].databaseId' 2>/dev/null || true)"
        [[ -n "$run_id" && "$run_id" != "null" ]] && break
    done
    [[ -n "$run_id" && "$run_id" != "null" ]] || die "Workflow run tidak ditemukan setelah trigger."

    log "Run ID: ${run_id} — menunggu selesai (bisa 10–20 menit)..."
    if [[ "$DRY_RUN" -eq 1 ]]; then
        log "[dry-run] Lewati gh run watch"
        echo "$run_id"
        return 0
    fi

    gh run watch "$run_id" --exit-status || die "Workflow run gagal. Cek: gh run view ${run_id} --log-failed"
    echo "$run_id"
}

find_latest_success_run() {
    local branch="$1"
    local run_id
    run_id="$(gh run list \
        --workflow="$WORKFLOW_FILE" \
        --branch="$branch" \
        --status=success \
        --limit 1 \
        --json databaseId \
        --jq '.[0].databaseId' 2>/dev/null || true)"
    [[ -n "$run_id" && "$run_id" != "null" ]] || die "Tidak ada workflow run sukses. Jalankan tanpa --latest dulu."
    log "Pakai run sukses terakhir: ${run_id}"
    echo "$run_id"
}

download_artifacts() {
    local run_id="$1"
    local dest="$2"

    rm -rf "$dest"
    mkdir -p "$dest"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        log "[dry-run] Download artifact dari run ${run_id} → ${dest}"
        return 0
    fi

    log "Download artifact dari run ${run_id}..."
    gh run download "$run_id" -D "$dest" \
        || die "Gagal download artifact. Run mungkin sudah expired (>30 hari)."

    ok "Artifact terdownload ke ${dest}"
}

prepare_release_assets() {
    local artifact_root="$1"
    local assets_dir="$2"
    local version="$3"

    rm -rf "$assets_dir"
    mkdir -p "$assets_dir"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        log "[dry-run] Siapkan asset release di ${assets_dir}"
        return 0
    fi

    # Paket lengkap (Ansible + semua binary)
    local dist_zip=""
    if [[ -f "${artifact_root}/galera-cluster-dist/galera-cluster-dist.zip" ]]; then
        dist_zip="${artifact_root}/galera-cluster-dist/galera-cluster-dist.zip"
    elif [[ -f "${artifact_root}/galera-cluster-dist.zip" ]]; then
        dist_zip="${artifact_root}/galera-cluster-dist.zip"
    else
        dist_zip="$(find "$artifact_root" -name 'galera-cluster-dist.zip' | head -1)"
    fi
    [[ -n "$dist_zip" && -f "$dist_zip" ]] || die "galera-cluster-dist.zip tidak ditemukan dalam artifact."

    cp "$dist_zip" "${assets_dir}/galera-cluster-dist-${version}.zip"
    ok "Asset: galera-cluster-dist-${version}.zip"

    # Binary per platform (zip terpisah untuk unduhan cepat)
    local plat artifact_dir inner bin_name zip_name
    for plat in "${PLATFORMS[@]}"; do
        artifact_dir="${artifact_root}/galera-tui-${plat}"
        [[ -d "$artifact_dir" ]] || die "Artifact platform hilang: galera-tui-${plat}"

        if [[ "$plat" == windows-x86_64 ]]; then
            bin_name="galera-tui.exe"
        else
            bin_name="galera-tui"
        fi
        [[ -f "${artifact_dir}/${bin_name}" ]] || die "Binary tidak ada: ${artifact_dir}/${bin_name}"

        inner="$(mktemp -d)"
        mkdir -p "${inner}/bin/${plat}"
        cp "${artifact_dir}/${bin_name}" "${inner}/bin/${plat}/"
        chmod +x "${inner}/bin/${plat}/"* 2>/dev/null || true

        zip_name="galera-tui-${plat}-${version}.zip"
        (cd "$inner" && zip -rq "${assets_dir}/${zip_name}" .)
        rm -rf "$inner"
        ok "Asset: ${zip_name}"
    done

    # Ringkasan platform untuk release notes
    {
        echo "## Galera Cluster ${version}"
        echo ""
        echo "Paket distribusi MariaDB Galera Cluster + HAProxy + TUI (**galera-tui**)."
        echo ""
        echo "### Unduhan"
        echo ""
        echo "| File | Isi |"
        echo "|------|-----|"
        echo "| \`galera-cluster-dist-${version}.zip\` | Ansible + semua binary + docs |"
        for plat in "${PLATFORMS[@]}"; do
            echo "| \`galera-tui-${plat}-${version}.zip\` | Binary TUI saja (${plat}) |"
        done
        echo ""
        echo "### Platform"
        echo ""
        echo "- \`darwin-aarch64\` — macOS Apple Silicon"
        echo "- \`darwin-x86_64\` — macOS Intel"
        echo "- \`linux-x86_64\` — Linux amd64"
        echo "- \`linux-aarch64\` — Linux ARM64"
        echo "- \`windows-x86_64\` — Windows amd64"
        echo ""
        echo "### Setup cepat"
        echo ""
        echo '```bash'
        echo "unzip galera-cluster-dist-${version}.zip -d galera-cluster-dist"
        echo "cd galera-cluster-dist"
        echo "./configure-inventory.sh"
        echo "cp group_vars/all/secrets.yml.example group_vars/all/secrets.yml"
        echo "cp group_vars_haproxy.yml.example group_vars_haproxy.yml"
        echo "./start.sh"
        echo '```'
        echo ""
        echo "Commit: \`$(git rev-parse --short HEAD)\`"
        echo "Workflow run: \`${RUN_ID:-unknown}\`"
    } > "${assets_dir}/RELEASE_NOTES.md"
}

create_tag() {
    local version="$1"
    if [[ "$SKIP_TAG_PUSH" -eq 1 ]]; then
        log "Lewati buat tag (--skip-tag)"
        return 0
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
        log "[dry-run] git tag -a ${version}"
        log "[dry-run] git push origin ${version}"
        return 0
    fi

    git tag -a "$version" -m "Release ${version}"
    git push origin "$version"
    ok "Tag ${version} di-push ke origin"
}

publish_release() {
    local version="$1"
    local assets_dir="$2"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        log "[dry-run] gh release create ${version} dengan asset di ${assets_dir}/"
        ls -la "$assets_dir" 2>/dev/null || true
        return 0
    fi

    local notes_arg=()
    if [[ -n "$NOTES_FILE" ]]; then
        notes_arg=(--notes-file "$NOTES_FILE")
    else
        notes_arg=(--notes-file "${assets_dir}/RELEASE_NOTES.md")
    fi

    local files=()
    local f
    shopt -s nullglob
    for f in "${assets_dir}"/*.zip; do
        files+=("$f")
    done
    shopt -u nullglob

    [[ ${#files[@]} -gt 0 ]] || die "Tidak ada file .zip untuk di-upload."

    log "Publish GitHub Release ${version}..."
    gh release create "$version" \
        --title "Galera Cluster ${version}" \
        "${notes_arg[@]}" \
        "${files[@]}"

    local url
    url="$(gh release view "$version" --json url --jq '.url')"
    ok "Release published: ${url}"
}

main() {
    parse_args "$@"
    preflight

    local branch
    branch="$(detect_branch)"
    log "Repo: ${REPO_ROOT}"
    log "Branch: ${branch}"
    log "Versi: ${VERSION}"

    if [[ "$BUMP_CARGO" -eq 1 ]]; then
        bump_cargo_version
    fi

    local run_id
    if [[ "$USE_LATEST" -eq 1 ]]; then
        run_id="$(find_latest_success_run "$branch")"
    else
        run_id="$(trigger_workflow "$branch")"
    fi
    RUN_ID="$run_id"

    local tmp_root
    tmp_root="$(mktemp -d)"
    trap 'rm -rf "${tmp_root}"' EXIT

    local artifact_root="${tmp_root}/artifacts"
    local assets_dir="${tmp_root}/release-assets"

    download_artifacts "$run_id" "$artifact_root"
    prepare_release_assets "$artifact_root" "$assets_dir" "$VERSION"
    create_tag "$VERSION"
    publish_release "$VERSION" "$assets_dir"

    echo ""
    ok "Selesai — release ${VERSION}"
    if [[ "$DRY_RUN" -eq 0 ]]; then
        gh release view "$VERSION" --web 2>/dev/null || gh release view "$VERSION"
    fi
}

main "$@"
