function run(input) {
  var text = input.text;
  var han = /[\u3400-\u9fff\uf900-\ufaff]/g;
  var hanCount = (text.match(han) || []).length;
  var latinWords = (text.replace(han, ' ').match(/\S+/g) || []).length;
  var characters = Array.from(text).length;
  var lines = text.split('\n').length;
  var labels = input.language === 'zh' ? ['字符', '字词', '行数'] : ['Characters', 'Words', 'Lines'];
  return { show: labels[0] + ' ' + characters + '\n' + labels[1] + ' ' + (hanCount + latinWords) + '\n' + labels[2] + ' ' + lines };
}
