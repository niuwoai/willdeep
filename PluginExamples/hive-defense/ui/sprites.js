(function () {
  'use strict';
  const keys = ['sting', 'bomb', 'pollen', 'barb', 'drum',
    'aphid', 'wasp', 'beetle', 'moth', 'spider', 'hornet', 'ant', 'caterpillar', 'grasshopper', 'flea', 'hive', 'repair-bee', 'bear', 'jungle'];
  const images = new Map();
  const ready = Promise.all(keys.map(key => new Promise((resolve, reject) => {
    const image = new Image();
    image.onload = () => { images.set(key, image); resolve(key); };
    image.onerror = () => reject(new Error('Missing sprite: ' + key));
    image.src = 'assets/' + key + '.png';
  })));
  function draw(context, key, x, y, size) {
    const image = images.get(key);
    if (!image) return;
    const scale = size / Math.max(image.naturalWidth, image.naturalHeight);
    const width = image.naturalWidth * scale;
    const height = image.naturalHeight * scale;
    context.drawImage(image, x - width / 2, y - height / 2, width, height);
  }
  window.HiveSprites = Object.freeze({ ready, draw, keys });
})();
