cmake_minimum_required(VERSION 3.24)

# Bu değişkenler project() çağrısından önce ayarlanmalıdır.
set(CMAKE_OSX_DEPLOYMENT_TARGET "12.0" CACHE STRING "Desteklenen en düşük macOS sürümü")
set(CMAKE_OSX_ARCHITECTURES "arm64;x86_64" CACHE STRING "Universal (Apple Silicon + Intel) derleme")

# Sürüm numarasının tek kaynağı VERSION dosyasıdır (uygulama ve kurulum paketi de kullanır).
file(STRINGS "${CMAKE_CURRENT_SOURCE_DIR}/VERSION" AIRSPEAKER_VERSION LIMIT_COUNT 1)

project(AirSpeaker VERSION ${AIRSPEAKER_VERSION} LANGUAGES C CXX OBJC)

if(NOT APPLE)
  message(FATAL_ERROR "AirSpeaker bir CoreAudio HAL eklentisidir ve yalnızca macOS üzerinde derlenebilir.")
endif()

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "Derleme türü" FORCE)
endif()

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

set(AIRSPEAKER_BUNDLE_ID "com.mylifer.airspeaker.driver" CACHE STRING "Sürücü paketinin CFBundleIdentifier değeri")
set(AIRSPEAKER_CODESIGN_IDENTITY "-" CACHE STRING "codesign kimliği ('-' = ad-hoc imza)")
option(AIRSPEAKER_WARNINGS_AS_ERRORS "Derleyici uyarılarını hata olarak değerlendir" OFF)

# Info.plist'teki CFPlugInFactories anahtarı. Değiştirilirse eklenti yeni bir
# fabrika olarak kaydolur; sabit tutulmalıdır.
set(AIRSPEAKER_FACTORY_UUID "BF54F349-72CC-492C-9819-32E507E58B6F")
set(AIRSPEAKER_EXECUTABLE_NAME "AirSpeaker")

set(AIRSPEAKER_WARNING_FLAGS -Wall -Wextra -Wshadow)
if(AIRSPEAKER_WARNINGS_AS_ERRORS)
  list(APPEND AIRSPEAKER_WARNING_FLAGS -Werror)
endif()

# --- HAL eklentisi: AirSpeaker.driver -----------------------------------------

configure_file(Driver/Info.plist.in "${CMAKE_CURRENT_BINARY_DIR}/Driver/Info.plist" @ONLY)

add_library(AirSpeakerDriver MODULE
  Driver/AirSpeakerDriver.cpp
  Driver/AirSpeakerConfig.h
)

set_target_properties(AirSpeakerDriver PROPERTIES
  BUNDLE TRUE
  BUNDLE_EXTENSION driver
  OUTPUT_NAME "${AIRSPEAKER_EXECUTABLE_NAME}"
  MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_BINARY_DIR}/Driver/Info.plist"
  LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}"
  CXX_VISIBILITY_PRESET hidden
  VISIBILITY_INLINES_HIDDEN ON
)

target_include_directories(AirSpeakerDriver PRIVATE Driver Shared/include)
target_compile_options(AirSpeakerDriver PRIVATE ${AIRSPEAKER_WARNING_FLAGS})
# Eklenti coreaudiod içinde çalışır; CoreAudio istemci kütüphanesine değil,
# yalnızca CoreFoundation'a bağlanır (AudioServerPlugIn.h yalnızca başlıktır).
target_link_libraries(AirSpeakerDriver PRIVATE "-framework CoreFoundation")

# Apple Silicon'da coreaudiod imzasız kod yüklemez; paketi (Info.plist dahil)
# imzala. Varsayılan ad-hoc imza yerel kullanım için yeterlidir.
add_custom_command(TARGET AirSpeakerDriver POST_BUILD
  COMMAND codesign --force --sign "${AIRSPEAKER_CODESIGN_IDENTITY}" --timestamp=none
          "$<TARGET_BUNDLE_DIR:AirSpeakerDriver>"
  COMMENT "AirSpeaker.driver imzalanıyor (${AIRSPEAKER_CODESIGN_IDENTITY})"
  VERBATIM
)

# --- Broker daemon: airspeaker-broker -------------------------------------------
#
# Sürücü (coreaudiod, sistem alanı) ile kullanıcı oturumundaki uygulama
# arasında paylaşımlı belleği aktaran LaunchDaemon. Bkz. Broker/main.c.

add_executable(airspeaker-broker Broker/main.c)
target_include_directories(airspeaker-broker PRIVATE Shared/include)
target_compile_options(airspeaker-broker PRIVATE ${AIRSPEAKER_WARNING_FLAGS})
add_custom_command(TARGET airspeaker-broker POST_BUILD
  COMMAND codesign --force --sign "${AIRSPEAKER_CODESIGN_IDENTITY}" --timestamp=none
          --identifier com.mylifer.airspeaker.broker "$<TARGET_FILE:airspeaker-broker>"
  VERBATIM
)

# --- Doğrulama aracı: airspeaker-check (Objective-C) ---------------------------

add_executable(airspeaker-check Tools/airspeaker-check.m)
target_include_directories(airspeaker-check PRIVATE Driver)
target_compile_options(airspeaker-check PRIVATE -fobjc-arc ${AIRSPEAKER_WARNING_FLAGS})
target_link_libraries(airspeaker-check PRIVATE "-framework Foundation" "-framework CoreAudio")

# --- Testler -------------------------------------------------------------------

enable_testing()
add_executable(ring-buffer-test tests/ring_buffer_test.c)
target_include_directories(ring-buffer-test PRIVATE Shared/include)
target_compile_options(ring-buffer-test PRIVATE ${AIRSPEAKER_WARNING_FLAGS})
add_test(NAME ring-buffer COMMAND ring-buffer-test)
