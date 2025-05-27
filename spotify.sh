#!/usr/bin/env bash

set -euo pipefail

VERSION_FILE="patched_versions.txt"

check_version() {
    local current_version=$1
    
    if [[ ! -s "$VERSION_FILE" ]]; then
        echo "[*] No previous versions found. Treating as new."
        return 1
    fi
    
    grep -Fxq "$current_version" "$VERSION_FILE" && {
        echo "[*] Version $current_version was patched before"
        return 0
    }
    
    echo "[*] New version detected: $current_version"
    return 1
}

save_version() {
    echo "$1" > "$VERSION_FILE"
    echo "[*] Saved version $1 to $VERSION_FILE"
}

req() {
    wget --header="User-Agent: Mozilla/5.0 (Android 13; Mobile; rv:125.0) Gecko/125.0 Firefox/125.0" \
         --header="Content-Type: application/octet-stream" \
         --header="Accept-Language: en-US,en;q=0.9" \
         --header="Connection: keep-alive" \
         --header="Upgrade-Insecure-Requests: 1" \
         --header="Cache-Control: max-age=0" \
         --header="Accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,image/apng,*/*;q=0.8" \
         --keep-session-cookies \
         --timeout=30 \
         -nv \
         ${2:+--output-document "$2"} \
         --content-disposition "$1"
}

download_github() {
    local page=$(req "https://api.github.com/repos/$1/$2/releases/latest" - 2>/dev/null)
    
    while read -r download_url asset_name; do
        [[ -n "$download_url" && -n "$asset_name" ]] && req "$download_url" "$asset_name"
    done <<< $(echo "$page" | jq -r '.assets[] | select(.name | endswith(".asc") | not) | "\(.browser_download_url) \(.name)"')
}

max() {
    local max="" num_ver num_max
    
    while read -r v || [[ -n "$v" ]]; do
        num_ver=$(echo "$v" | grep -o '[0-9]\+' | paste -sd '')
        [[ -z "$max" ]] && { max=$v; continue; }
        
        num_max=$(echo "$max" | grep -o '[0-9]\+' | paste -sd '')
        (( num_ver > num_max )) && max=$v
    done
    
    echo "$max"
}

get_latest_version() {
    grep -Evi 'alpha|beta' | grep -oPi '\b\d+(\.\d+)+(?:-\w+)?(?:\.\d+)?(?:\.\w+)?\b' | max
}

get_apkpure_latest_version() {
    req "https://apkpure.net/spotify-music-and-podcasts-for-android/com.spotify.music/versions" - \
        | grep -oP 'data-dt-version="\K[^"]*' | sed 10q | get_latest_version
}

download_apk_from_apkpure() {
    local url="https://apkpure.net/spotify-music-and-podcasts-for-android/com.spotify.music/download/$1"
    local download_link=$(req "$url" - | grep -oP '<a[^>]*id="download_link"[^>]*href="\K[^"]*' | head -n 1)
    
    local before_download=(*)
    req "$download_link"
    local after_download=(*)
    
    for file in "${after_download[@]}"; do
        [[ ! " ${before_download[*]} " =~ " $file " ]] && { echo "$file"; return; }
    done
    
    echo "[!] Error: Could not determine downloaded file name!" >&2
    exit 1
}

get_uptodown_latest_version() {
    req "https://spotify.en.uptodown.com/android/versions" - \
        | grep -oP 'class="version">\K[^<]+' | get_latest_version
}

download_apk_from_uptodown() {
    local page=$(req "https://spotify.en.uptodown.com/android/versions" -)
    local download_url=$(echo "$page" | grep -B3 '"version">'$1'<' \
                          | sed -n 's/.*data-url="\([^"]*\)".*/\1/p' \
                          | sed -n '1p')-x
    
    local download_link="https://dw.uptodown.com/dwn/$(req "$download_url" - \
                          | grep 'id="detail-download-button"' -A2 \
                          | sed -n 's/.*data-url="\([^"]*\)".*/\1/p' \
                          | sed -n '1p')"
    
    local before_download=(*)
    req "$download_link"
    local after_download=(*)
    
    for file in "${after_download[@]}"; do
        [[ ! " ${before_download[*]} " =~ " $file " ]] && { echo "$file"; return; }
    done
    
    echo "[!] Error: Could not determine downloaded file name!" >&2
    exit 1
}

main() {
    # local version=$(get_apkpure_latest_version)
    version="9.0.46.496"
    echo "[*] Latest version found: $version"

    check_version "$version" && { echo "[*] Version $version was already patched - skipping build"; exit 0; }
    
    echo "[*] New version detected - proceeding with build"
    
    download_github "revanced" "revanced-patches"
    download_github "revanced" "revanced-cli"

    local APK_FILE=$(download_apk_from_apkpure "$version")
    echo "[*] Downloaded APK file: $APK_FILE"

    local APKSIGNER=$(find "${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}/build-tools" -name apksigner -type f | sort -Vr | head -n 1)

    if [[ "$APK_FILE" != *.apk ]]; then
        echo "[*] File is not .apk, merging files..."
        download_github "REAndroid" "APKeditor"
        
        local MERGED_APK="${APK_FILE%.*}.apk"
        java -jar APKEditor*.jar m -i "$APK_FILE" -o "$MERGED_APK" 2>/dev/null
        APK_FILE="$MERGED_APK"
    fi
    
    zip -d "$APK_FILE" "lib/armeabi-v7a/*" "lib/x86/*" "lib/x86_64/*" >/dev/null || echo "[!] Skipping missing architectures."

    echo "[*] Patching and signing..."
    java -jar revanced-cli*.jar patch --patches patches*.rvp --out "patched-spotify-v$version.apk" "$APK_FILE" -e "Change package name" || exit 1

    local SIGNED_APK="Spotify-ReVanced-v$version.apk"
    "$APKSIGNER" sign --ks public.jks --ks-key-alias public \
        --ks-pass pass:public --key-pass pass:public --out "$SIGNED_APK" "patched-spotify-v$version.apk"

    echo "[✔] Signed APK: $SIGNED_APK"
    save_version "$version"
}

main "$@"
