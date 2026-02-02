#!/bin/bash
set -e

# Проверка необходимых зависимостей
check_deps() {
    local deps=("git" "curl" "unzip" "cmake" "ninja" "python3")
    local missing=()
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing+=("$dep")
        fi
    done
    
    if [ ${#missing[@]} -ne 0 ]; then
        echo "ERROR: Missing dependencies: ${missing[*]}"
        exit 1
    fi
}

check_deps

# Настройки
ASEPRITE_VERSION="${ASEPRITE_VERSION:-}"
SKIA_VERSION=""

# Клонирование/обновление репозитория aseprite
if [ ! -d "aseprite" ]; then
    git clone --recursive --tags https://github.com/aseprite/aseprite.git aseprite || \
        { echo "failed to clone repo"; exit 1; }
else
    git -C aseprite fetch --tags || { echo "failed to fetch repo"; exit 1; }
fi

# Получение последнего тега, если версия не указана
if [ -z "$ASEPRITE_VERSION" ]; then
    ASEPRITE_VERSION=$(git -C aseprite tag --sort=creatordate | tail -1)
fi

echo "building $ASEPRITE_VERSION"

# Обновление репозитория до выбранного тега
git -C aseprite clean -fdx
git -C aseprite submodule foreach --recursive git clean -xfd
git -C aseprite fetch --depth=1 --no-tags origin "$ASEPRITE_VERSION:refs/remotes/origin/$ASEPRITE_VERSION" || \
    { echo "failed to fetch repo"; exit 1; }
git -C aseprite reset --hard "origin/$ASEPRITE_VERSION" || { echo "failed to update repo"; exit 1; }
git -C aseprite submodule update --init --recursive || { echo "failed to update submodules"; exit 1; }

# Обновление версии в CMakeLists.txt
python3 -c "
v = open('aseprite/src/ver/CMakeLists.txt').read()
open('aseprite/src/ver/CMakeLists.txt', 'w').write(v.replace('1.x-dev', '${ASEPRITE_VERSION:1}'))
"

# Определение версии Skia
if [ -f "aseprite/laf/misc/skia-tag.txt" ]; then
    SKIA_VERSION=$(cat aseprite/laf/misc/skia-tag.txt)
else
    if [[ "$ASEPRITE_VERSION" == *beta* ]]; then
        SKIA_VERSION="m124-08a5439a6b"
    else
        SKIA_VERSION="m102-861e4743af"
    fi
fi

# Скачивание Skia
if [ ! -d "skia-$SKIA_VERSION" ]; then
    mkdir "skia-$SKIA_VERSION"
    pushd "skia-$SKIA_VERSION" > /dev/null
    curl -L -o "Skia-Linux-Release-x64.zip" \
        "https://github.com/aseprite/skia/releases/download/$SKIA_VERSION/Skia-Linux-Release-x64.zip" || \
        { echo "failed to download skia"; exit 1; }
    unzip -q "Skia-Linux-Release-x64.zip"
    popd > /dev/null
fi

# Сборка aseprite
if [ -d "build" ]; then
    rm -rf build
fi

cmake \
    -G Ninja \
    -S aseprite \
    -B build \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DCMAKE_POLICY_DEFAULT_CMP0074=NEW \
    -DCMAKE_POLICY_DEFAULT_CMP0091=NEW \
    -DCMAKE_POLICY_DEFAULT_CMP0092=NEW \
    -DENABLE_CCACHE=OFF \
    -DOPENSSL_USE_STATIC_LIBS=TRUE \
    -DLAF_BACKEND=skia \
    -DSKIA_DIR="$(pwd)/skia-$SKIA_VERSION" \
    -DSKIA_LIBRARY_DIR="$(pwd)/skia-$SKIA_VERSION/out/Release-x64" || \
    { echo "failed to configure build"; exit 1; }

ninja -C build || { echo "build failed"; exit 1; }

# Создание выходной папки
OUTPUT_DIR="aseprite-$ASEPRITE_VERSION"
mkdir -p "$OUTPUT_DIR"
echo "# This file is here so Aseprite behaves as a portable program" > "$OUTPUT_DIR/aseprite.ini"
cp -r aseprite/docs "$OUTPUT_DIR/"
cp build/bin/aseprite "$OUTPUT_DIR/"
cp -r build/bin/data "$OUTPUT_DIR/"

# Для GitHub Actions
if [ -n "$GITHUB_WORKFLOW" ]; then
    mkdir -p github
    mv "$OUTPUT_DIR" github/
    echo "ASEPRITE_VERSION=$ASEPRITE_VERSION" >> "$GITHUB_OUTPUT"
fi

echo "Build completed successfully!"
