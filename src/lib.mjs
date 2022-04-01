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

setInterval(__wbc.yieldToC, 10);
setInterval(__wbc.checkBarSize, 100);

// Load all scripts within the `blocks` dir
const [files, err] = os.readdir('./blocks');
if (err) {
	console.log('Failed to open directory "blocks", does it exist?');
	std.exit(1);
}
files.filter(f => !f.startsWith('.')).forEach(script => {
	std.loadScript('./blocks/' + script);
});
