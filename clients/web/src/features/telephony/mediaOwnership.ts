// Synchronous launch guard: a dial or answer reserves ownership before an API
// request can yield, so another surface cannot open a microphone concurrently.
let phoneMediaBusy = false;
export function phoneMediaIsBusy(): boolean { return phoneMediaBusy; }
export function setPhoneMediaBusy(busy: boolean): void { phoneMediaBusy = busy; }
