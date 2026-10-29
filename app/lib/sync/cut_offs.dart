/// Runs cut off in a row. One now and then is the network going (nothing wrong); [shown]
/// in a row is a problem the person should see: every run hung on a Wi-Fi with broken
/// IPv6 for an afternoon with nothing on screen (owner 2026-10-29). A run the app left the
/// screen during is cut off by the system, and not counted.
class CutOffs {
  static const shown = 3;

  int count = 0;
  bool _wentAway = false;

  /// A run starts.
  void start() => _wentAway = false;

  /// The app left the screen.
  void away() => _wentAway = true;

  /// A sync went through.
  void ok() => count = 0;

  /// The run was cut off: whether to show the problem now.
  bool cutOff() => !_wentAway && ++count >= shown;
}
