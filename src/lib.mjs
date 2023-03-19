import * as std from 'std';
import * as os from 'os';
globalThis.std = std;
globalThis.os = os;

globalThis.setInterval = (fn, interval) => {
    const wfn = () => {
        fn();
        os.setTimeout(wfn, interval);
    };
    os.setTimeout(wfn, interval);
};
// TODO: clearInterval
setInterval(wb.internal.yield, 10);

globalThis.$quote = arg => {
    // Sources:
    // - https://stackoverflow.com/a/47469792
    // - https://docs.microsoft.com/en-gb/archive/blogs/twistylittlepassagesallalike/everyone-quotes-command-line-arguments-the-wrong-way
    if (!(/[ \t\n\v]/.exec(arg))) {
        return arg;
    }
    let str = '"';
    for (let i = 0; i < arg.length; i++) {
        let slashes = 0;
        while (i < arg.length && arg[i] === '\\') {
            slashes++;
            i++;
        }
        if (i === arg.length) {
            str += '\\'.repeat(slashes * 2);
            break;
        } else if (arg[i] === '"') {
            str += '\\'.repeat(slashes * 2 + 1) + arg[i];
        } else {
            str += '\\'.repeat(slashes) + arg[i];
        }
    }
    return str + '"';
};

globalThis.$ps = async cmd => await $(`powershell -Command ${globalThis.$quote(cmd)}`);

globalThis.$psFetch = async url => {
    const cmd = `$ProgressPreference='SilentlyContinue';$(Invoke-WebRequest '${url.replace(/'/g, "''")}').Content`;
    return await globalThis.$ps(cmd);
};

// TODO: colored info, warn, error
console.error = (...args) => std.err.printf('%s\n', args.join(' '));;

console.log("Hello from lib.mjs!");
const a = wb.createBlock();
a.setFont('Comic Sans MS', 30);
a.setColor(255, 0, 0, 255);
a.setText('Red');
const b = wb.createBlock();
b.setFont('Arial Black', 30);
b.setColor(0, 255, 0, 255);
b.setText('Green');
const c = wb.createBlock();
c.setColor(0, 0, 255, 255);
c.setText('Blue');
const d = wb.createBlock();
d.setColor(255, 255, 255, 100);
d.setPadding(20, 20);
d.setText('Alpha');
const e = wb.createBlock();
e.setVisible(false);
e.setText('Invisible');

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