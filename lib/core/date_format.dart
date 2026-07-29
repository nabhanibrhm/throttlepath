/// Month names, in the two lengths the app uses.
///
/// Both lists were previously re-declared in four separate screens. They are
/// hard-coded rather than taken from `intl`: the app ships no localisations, so a
/// locale-aware formatter would buy nothing but a dependency, and these names are
/// part of the layout — "September" has to fit a month header that was measured
/// with it in place.
library;

const List<String> _short = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

const List<String> _long = [
  'January', 'February', 'March', 'April', 'May', 'June', //
  'July', 'August', 'September', 'October', 'November', 'December',
];

/// e.g. `Jul`. [month] is 1-based, matching [DateTime.month].
String shortMonth(int month) => _short[month - 1];

/// e.g. `July`. [month] is 1-based, matching [DateTime.month].
String longMonth(int month) => _long[month - 1];
