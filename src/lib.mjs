import * as std from 'std';
import * as os from 'os';
globalThis.std = std;
globalThis.os = os;

// setInterval polyfill ---------------------------------------------------- //
let intervalCount = 0;
const intervalMap = {};
globalThis.setInterval = (fn, interval) => {
    let id = ++intervalCount;
    const wfn = () => {
        intervalMap[id] = os.setTimeout(wfn, interval);
        fn();
    };
    intervalMap[id] = os.setTimeout(wfn, interval);
    return id;
};
globalThis.clearInterval = id => {
    if (intervalMap[id] === undefined) return;
    os.clearTimeout(intervalMap[id]);
    delete intervalMap[id];
};
// ------------------------------------------------------------------------- //

globalThis.$quote = wb.internal.shell_quote;
globalThis.$ps = async cmd => await $(`powershell -Command ${globalThis.$quote(cmd)}`);

globalThis.$psFetch = async url => {
    const cmd = `$ProgressPreference='SilentlyContinue';$(Invoke-WebRequest '${url.replace(/'/g, "''")}').Content`;
    return await globalThis.$ps(cmd);
};

setInterval(wb.internal.yield, 10);

// TODO: colored info, warn, error
console.error = (...args) => std.err.printf('%s\n', args.join(' '));;

console.log("Hello from lib.mjs!");
const a = wb.createBlock();
a.setFont('Comic Sans MS', 25);
a.setColor(255, 0, 0, 255);
a.setText('Red');
const b = wb.createBlock();
b.setFont('Arial Black', 25);
b.setColor(0, 255, 0, 255);
b.setText('Green');
const c = wb.createBlock();
c.setColor(0, 0, 255, 255);
c.setText('Blue');
const d = wb.createBlock();
d.setColor(255, 255, 255, 100);
d.setFont('Courier New', 25);
d.setPadding(20, 20);
d.setText('Alpha');
const e = wb.createBlock();
e.setVisible(false);
e.setText('Invisible');
const f = wb.createBlock();
f.setFont('Consolas', 8);
f.setColor(255, 255, 255, 255);
f.setText('White');

console.log($quote('"Yo \\" hello oo"'))

// Load all scripts within the `blocks` dir
// const [files, err] = os.readdir('./blocks');
// if (err) {
//     console.error('Failed to open directory "blocks", does it exist?');
//     std.exit(1);
// }
// files.filter(f => !f.startsWith('.')).sort().forEach(script => {
//     std.out.printf('Loading %s... ', script);
//     const data = std.loadFile('./blocks/' + script);
//     if (!data) {
//         throw 'Failed to load ' + data;
//     }
//     try {
//         (() => {
//             eval(data);
//         })();
//         std.out.printf('OK!\n');
//     } catch (ex) {
//         console.error(`Error running script '${script}':`, ex);
//     }
// });