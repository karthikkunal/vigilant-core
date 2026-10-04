/// Formatters and choices shared by the monitor screens.
///
/// These were duplicated per screen: the cadence list three times, the cadence
/// label three times, and the error prettifier seven. A monitor form is a form;
/// these are the parts every form needs, so they live in one place.
library;

/// Cadence choices offered when creating or editing a monitor, in minutes.
///
/// One minute is the floor because the foreground service repeats every 60s; a
/// shorter cadence could not be honoured.
const List<int> kCadenceMinutes = [1, 5, 10, 15, 30, 60];

/// The default cadence for a new monitor, in minutes.
const int kDefaultCadenceMinutes = 5;

/// Human label for a cadence in minutes: `5 min`, `1 hr`.
String cadenceLabel(int minutes) =>
    minutes < 60 ? '$minutes min' : '${minutes ~/ 60} hr';

/// Strips the Dart and Flutter exception prefixes that mean nothing to someone
/// looking at a form, so a validation failure reads as a sentence rather than a
/// type dump.
///
/// The prefix list is the union of what the screens used to strip individually.
/// `DiscoveryException` came from the scan screen and `PlatformException` from
/// the screens that talk to plugins; `Invalid argument(s)` came from the
/// coordinator's validation. Keeping all of them means no screen lost a prefix
/// in the consolidation.
String friendlyMonitorError(Object error) {
  final text = error.toString();
  return text
      .replaceFirst('Exception: ', '')
      .replaceFirst('PlatformException: ', '')
      .replaceFirst('DiscoveryException: ', '')
      .replaceFirst('StateError: ', '')
      .replaceFirst('Invalid argument(s): ', '');
}
