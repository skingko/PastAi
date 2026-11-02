function run(input) {
  var text = input.text;
  var han = /[\u3400-\u9fff\uf900-\ufaff]/g;
  var hanCount = (text.match(han) || []).length;
  var latinWords = (text.replace(han, ' ').match(/\S+/g) || []).length;
  var characters = Array.from(text).length;
  var lines = text.split('\n').length;
  return { show: '字符 ' + characters + '\n字词 ' + (hanCount + latinWords) + '\n行数 ' + lines };
}
