#!/usr/bin/env bash
# Runs the attack tests only (see test/security/README.md). They are part of `flutter test` as well.
set -euo pipefail
cd "$(dirname "$0")/.."
flutter test \
  test/security \
  test/collab/signaling_test.dart test/collab/signaling_limits_test.dart test/collab/collab_service_test.dart \
  test/devicesync/sync_session_test.dart test/devicesync/sync_keys_test.dart test/devicesync/sync_room_privacy_test.dart \
  test/nativeshare/shared_folder_sync_test.dart test/cloudsync/folder_sync_test.dart \
  test/hostile_input_test.dart test/capture_private_hosts_test.dart test/capture_link_test.dart \
  test/import_document_images_test.dart test/extensions/service_test.dart
