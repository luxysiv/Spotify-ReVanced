#!/usr/bin/env bash

set -euo pipefail

# Add variable to save file version
VERSION_FILE="patched_versions.txt"

# Function to check patched version
check_version() {
    local current_version=$1
    
    if [[ ! -s "$VERSION_FILE" ]]; then
        echo "[*] No previous versions found. Treating as new."
        return 1
    fi
    
    if grep -Fxq "$current_version" "$VERSION_FILE"; then
        echo "[*] Version $current_version was patched before"
        return 0
    else
        echo "[*] New version detected: $current_version"
        return 1
    fi
}
# Function save new version
save_version() {
    local version=$1
    echo "$version" > "$VERSION_FILE"
    echo "[*] Saved version $version to $VERSION_FILE"
}

# Function to send request mimicking Firefox Android
req() {
    local url=$1
    local output_file=${2:-}
    
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
         ${output_file:+--output-document "$output_file"} \
         --content-disposition "$url"
}

# Function to download necessary resources from GitHub
download_github() {
    local name=$1
    local repo=$2
    local github_api_url="https://api.github.com/repos/$name/$repo/releases/latest"
    local page
    page=$(req "$github_api_url" - 2>/dev/null)
    
    if ! command -v jq &> /dev/null; then
        echo "Error: jq is required but not installed. Please install jq first." >&2
        exit 1
    fi
    
    local asset_urls
    asset_urls=$(echo "$page" | jq -r '.assets[] | select(.name | endswith(".asc") | not) | "\(.browser_download_url) \(.name)"')
    
    while read -r download_url asset_name; do
        if [[ -n "$download_url" && -n "$asset_name" ]]; then
            req "$download_url" "$asset_name"
        fi
    done <<< "$asset_urls"
}

# Find maximum version
max() {
    local max=""
    local num_ver num_max
    
    while read -r v || [[ -n "$v" ]]; do
        num_ver=$(echo "$v" | grep -o '[0-9]\+' | paste -sd '')
        if [[ -z "$max" ]]; then
            max=$v
            continue
        fi
        
        num_max=$(echo "$max" | grep -o '[0-9]\+' | paste -sd '')
        if [[ "$num_ver" -gt "$num_max" ]]; then 
            max=$v
        fi
    done
    
    echo "$max"
}

# Get latest stable version
get_latest_version() {
    grep -Evi 'alpha|beta' | grep -oPi '\b\d+(\.\d+)+(?:-\w+)?(?:\.\d+)?(?:\.\w+)?\b' | max
}

get_apkpure_latest_version() {
    local name="spotify-music-and-podcasts-for-android"
    local package="com.spotify.music"
    local url="https://apkpure.net/$name/$package/versions"

    local version
    version=$(req "$url" - | grep -oP 'data-dt-version="\K[^"]*' | sed 10q | get_latest_version)
    
    if [[ -z "$version" ]]; then
        echo "[!] Error: Could not find a valid version!" >&2
        exit 1
    fi

    echo "$version"
}

download_apk_from_apkpure() {
    local version=$1
    local name="spotify-music-and-podcasts-for-android"
    local package="com.spotify.music"
    local url="https://apkpure.net/$name/$package/download/$version"

    local download_link
    download_link=$(req "$url" - | grep -oP '<a[^>]*id="download_link"[^>]*href="\K[^"]*' | head -n 1)

    if [[ -z "$download_link" ]]; then
        echo "[!] Error: Could not get download link!" >&2
        exit 1
    fi

    # Get file list before download
    local before_download
    before_download=(*)

    # Download file to current directory
    req "$download_link"

    # Get file list after download
    local after_download
    after_download=(*)

    # Find new file
    local file
    for file in "${after_download[@]}"; do
        if [[ ! " ${before_download[*]} " =~ " $file " ]]; then
            echo "$file"
            return
        fi
    done

    echo "[!] Error: Could not determine downloaded file name!" >&2
    exit 1
}

get_uptodown_latest_version() {
    local name="spotify"
    local url="https://$name.en.uptodown.com/android/versions"

    local version
    version=$(req "$url" - | grep -oP 'class="version">\K[^<]+' | get_latest_version)
    
    if [[ -z "$version" ]]; then
        echo "[!] Error: Could not find a valid version!" >&2
        exit 1
    fi

    echo "$version"
}

download_apk_from_uptodown() {
    local version=$1
    local name="spotify"
    local url="https://$name.en.uptodown.com/android/versions"

    local download_url
    download_url="$(req "$url" - | grep -B3 '"version">'$version'<' \
                                 | sed -n 's/.*data-url="\([^"]*\)".*/\1/p' \
                                 | sed -n '1p')-x"
    if [[ -z "$download_url" ]]; then
        echo "[!] Error: Could not get download url!" >&2
        exit 1
    fi

    local download_link
    download_link="https://dw.uptodown.com/dwn/$(req "$download_url" - | grep 'id="detail-download-button"' -A2 \
                                                                       | sed -n 's/.*data-url="\([^"]*\)".*/\1/p' \
                                                                       | sed -n '1p')"
    if [[ -z "$download_link" ]]; then
        echo "[!] Error: Could not get download link!" >&2
        exit 1
    fi

    # Get file list before download
    local before_download
    before_download=(*)

    # Download file to current directory
    req "$download_link"

    # Get file list after download
    local after_download
    after_download=(*)

    # Find new file
    local file
    for file in "${after_download[@]}"; do
        if [[ ! " ${before_download[*]} " =~ " $file " ]]; then
            echo "$file"
            return
        fi
    done

    echo "[!] Error: Could not determine downloaded file name!" >&2
    exit 1
}

main() {
    # Get latest version
    local version
    version=$(get_apkpure_latest_version)
    echo "[*] Latest version found: $version"

    # Check if version already patched
    if check_version "$version"; then
        echo "[*] Version $version was already patched - skipping build"
        exit 0
    fi
    
    echo "[*] New version detected - proceeding with build"
    
    # Download necessary tools only if needed
    download_github "revanced" "revanced-patches"
    download_github "revanced" "revanced-cli"

    # Download APK
    local APKs_FILE
    APKs_FILE=$(download_apk_from_apkpure "$version")
    echo "[*] Downloaded APK file: $APKs_FILE"

    # Verify APK download
    if [[ ! -f "$APKs_FILE" ]]; then
        echo "[!] Error: Failed to download APK file!" >&2
        exit 1
    fi

    # Find apksigner
    local APKSIGNER
    if command -v apksigner &> /dev/null; then
        APKSIGNER="apksigner"
    else
        APKSIGNER=$(find "${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}/build-tools" -name apksigner -type f | sort -Vr | head -n 1)
    fi

    if [[ -z "$APKSIGNER" ]]; then
        echo "[!] Error: Could not find 'apksigner'. Please install Android SDK Build-Tools!" >&2
        exit 1
    fi

    # Process based on file type
    if [[ "$APKs_FILE" == *.xapk ]]; then
        echo "[*] File is .xapk, merging files..."

        download_github "REAndroid" "APKeditor"

        # Merge file
        java -jar APKEditor*.jar m -i "$APKs_FILE" 2>/dev/null

        # Find merged file
        local merged_apk
        merged_apk=$(ls *_merged.apk 2>/dev/null | head -n 1)
        if [[ -z "$merged_apk" ]]; then
            echo "[!] Error: Could not find merged APK file!" >&2
            exit 1
        fi

        # Remove other architectures
        echo "[*] Filtering architectures in merged APK..."
        zip -d "$merged_apk" \
            "lib/armeabi-v7a/*" \
            "lib/x86/*" \
            "lib/x86_64/*" \
            "lib/armeabi/*" \
            >/dev/null || echo "[!] Skipping missing architectures."

        # Patch merged APK
        java -jar revanced-cli*.jar patch --patches patches*.rvp --out "patched-spotify-v$version.apk" "$merged_apk" || exit 1

        # Sign
        local SIGNED_APK="Spotify-ReVanced-v$version.apk"
        "$APKSIGNER" sign --ks public.jks --ks-key-alias public \
            --ks-pass pass:public --key-pass pass:public --out "$SIGNED_APK" "patched-spotify-v$version.apk"

        echo "[✔] Signed APK: $SIGNED_APK"
    else
        echo "[*] File is APK, filtering architectures..."

        # Remove other architectures
        zip -d "$APKs_FILE" \
            "lib/armeabi-v7a/*" \
            "lib/x86/*" \
            "lib/x86_64/*" \
            "lib/armeabi/*" \
            >/dev/null || echo "[!] Skipping missing architectures."

        echo "[*] Patching and signing..."

        # Patch APK
        java -jar revanced-cli*.jar patch --patches patches*.rvp --out "patched-spotify-v$version.apk" "$APKs_FILE" || exit 1

        # Sign
        local SIGNED_APK="Spotify-ReVanced-v$version.apk"
        "$APKSIGNER" sign --ks public.jks --ks-key-alias public \
            --ks-pass pass:public --key-pass pass:public --out "$SIGNED_APK" "patched-spotify-v$version.apk"

        echo "[✔] Signed APK: $SIGNED_APK"
    fi

    # Save version to patched_text
    save_version "$version"
}

main "$@"
