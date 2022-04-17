const net = require('net');
const child_process = require('child_process');

const connectQemuSocket = (socketPath) => new Promise((resolve, reject) => {
  const socket = net.connect({
    path: socketPath
  }, (err) => {
    if(err) {
      reject(err);
      return;
    }

    // result processing
    const responseHandlerQueue = [];
    let currentLine = '';
    socket.on('data', (buf) => {
      let start = 0;
      for(let i = 0; i < buf.length; ++i) {
        if(buf[i] != '\n') continue;
        currentLine += buf.substring(start, i);
        start = i + 1;
        if(currentLine.length) {
          const result = JSON.parse(currentLine);
          currentLine = '';
          if(!('return' in result)) continue;
          const handler = responseHandlerQueue[0];
          responseHandlerQueue.splice(0, 1);
          handler(result);
        }
      }
    });

    const request = (method, args) => new Promise((resolve, reject) => {
      responseHandlerQueue.push(resolve);
      socket.write(`${JSON.stringify({
        execute: method,
        arguments: args
      })}\n`);
    });

    resolve({
      request,
      // https://stuff.mit.edu/afs/sipb/project/exokernel/share/doc/qemu/qmp-commands.txt
      sendKeys: (keys) => request('send-key', { keys }),
      screenshot: async () => {
        const filename = `${process.cwd()}/screenshot`;
        await request('screendump', {
          filename
        });
        return filename;
      },
      close: () => {
        socket.end();
      },
    });
  });
  socket.setEncoding('utf8');
  socket.on('error', reject);
});

const sleep = (timeout) => new Promise((resolve, reject) => setTimeout(resolve, timeout));

// https://en.wikibooks.org/wiki/QEMU/Monitor#sendkey_keys
// https://manpages.ubuntu.com/manpages/bionic/man7/qemu-qmp-ref.7.html
const syms = {
  ' ': 'spc',
  '`': 'grave_accent',
  '~': 'shift-grave_accent',
  '!': 'shift-1',
  '@': 'shift-2',
  '#': 'shift-3',
  '$': 'shift-4',
  '%': 'shift-5',
  '^': 'shift-6',
  '&': 'shift-7',
  '*': 'shift-8',
  '(': 'shift-9',
  ')': 'shift-0',
  '-': 'minus',
  '_': 'shift-minus',
  '=': 'equal',
  '+': 'shift-equal',
  '[': 'bracket_left',
  ']': 'bracket_right',
  '{': 'shift-bracket_left',
  '}': 'shift-bracket_right',
  ',': 'comma',
  '.': 'dot',
  '<': 'shift-comma',
  '>': 'shift-dot',
  '/': 'slash',
  '?': 'shift-slash',
  ';': 'semicolon',
  ':': 'shift-semicolon',
  '\'': 'apostrophe',
  '"': 'shift-apostrophe',
  '\\': 'backslash',
  '|': 'shift-backslash',
  '\n': 'ret',
};

const typeText = async (socket, s) => {
  for(let i = 0; i < s.length; ++i) {
    let c = s[i];
    let q = [];
    if(c >= 'A' && c <= 'Z') {
      c = `shift-${c.toLowerCase()}`;
    } else if(syms[c]) {
      c = syms[c];
    }
    await typeSym(socket, c);
  }
};

const typeSym = (socket, s) => socket.sendKeys(s.split('-').map((c) => ({
  type: 'qcode',
  data: c
})));

(async () => {
  const socket = await connectQemuSocket(process.env.SOCKET_PATH);

  await socket.request('qmp_capabilities');

  const detectText = async (text) => {
    const screenshotFileName = await socket.screenshot();
    const output = await new Promise((resolve, reject) => {
      const p = child_process.spawn('tesseract', [
        screenshotFileName,
        '-', '--psm', '11', '--dpi', '72', '-l', 'eng'
      ], {
        stdio: ['ignore', 'pipe', 'ignore']
      });
      let output = '';
      p.stdout.on('data', (data) => {
        output += data;
      });
      p.on('close', (code) => code == 0 ? resolve(output) : reject(code));
    });

    return output.indexOf(text) >= 0;
  };

  const waitForText = async (message, text, seconds) => {
    console.log(`${message}...`);
    for(let i = 0; i < seconds; ++i) {
      await sleep(1000);

      if(await detectText(text)) {
        console.log(`${message}: finished.`);
        return;
      }
    }
    throw `${message}: timed out!`;
  };

  await waitForText('Waiting for boot', 'macOS Utilities', 300);

  console.log('Starting terminal.');
  await typeSym(socket, 'ctrl-f2');
  await sleep(1000);
  await typeText(socket, 'u\nt\n');

  await waitForText('Waiting for terminal', 'bash', 10);

  console.log('Starting init script.');
  await typeText(socket, '/Volumes/QEMU\\ VVFAT/init.sh\n');

  console.log('Done.');
  socket.close();
})()
