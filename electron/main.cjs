'use strict';

const { app, BrowserWindow, shell } = require('electron');
const path = require('node:path');

const APP_URL = 'https://zekariyas-ui.github.io/EDUMAK/';
const APP_ORIGIN = new URL(APP_URL).origin;
const APP_PATH_PREFIX = '/EDUMAK/';

function isAppUrl(value) {
  try {
    const url = new URL(value);
    return url.origin === APP_ORIGIN && url.pathname.startsWith(APP_PATH_PREFIX);
  } catch {
    return false;
  }
}

function openExternal(value) {
  try {
    const url = new URL(value);
    if (url.protocol === 'https:' || url.protocol === 'http:') {
      shell.openExternal(url.href);
    }
  } catch {
    // Ignore malformed or unsupported URLs.
  }
}

function createWindow() {
  const win = new BrowserWindow({
    width: 1360,
    height: 900,
    minWidth: 900,
    minHeight: 650,
    show: false,
    autoHideMenuBar: true,
    title: 'EDUMAK',
    icon: path.join(__dirname, '..', 'build', 'edumak.ico'),
    backgroundColor: '#f5f7fc',
    webPreferences: {
      nodeIntegration: false,
      contextIsolation: true,
      sandbox: true,
      webSecurity: true
    }
  });

  win.once('ready-to-show', () => win.show());

  win.webContents.setWindowOpenHandler(({ url }) => {
    openExternal(url);
    return { action: 'deny' };
  });

  win.webContents.on('will-navigate', (event, url) => {
    if (!isAppUrl(url)) {
      event.preventDefault();
      openExternal(url);
    }
  });

  win.loadURL(APP_URL);
}

app.whenReady().then(() => {
  createWindow();
  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') app.quit();
});
