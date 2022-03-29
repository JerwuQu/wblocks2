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

std.loadScript("wblocks.js");
