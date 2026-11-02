function run(input) {
  var text = input.text;
  return text === text.toUpperCase() ? text.toLowerCase() : text.toUpperCase();
}
