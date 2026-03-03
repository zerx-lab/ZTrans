/*
    SPDX-License-Identifier: MIT
*/

const GAP = 12;
const trackedWindows = new Map();

function normalize(value) {
    return typeof value === "string" ? value.toLowerCase() : "";
}

function matchesZTrans(window) {
    if (!window || !window.normalWindow) {
        return false;
    }

    const caption = normalize(window.caption);
    const desktopFileName = normalize(window.desktopFileName);
    const resourceName = normalize(window.resourceName);
    const resourceClass = normalize(window.resourceClass);
    const windowRole = normalize(window.windowRole);

    return caption === "ztrans" ||
        caption.startsWith("ztrans <") ||
        desktopFileName === "ztrans" ||
        desktopFileName.endsWith("/ztrans.desktop") ||
        resourceName === "ztrans" ||
        resourceClass === "ztrans" ||
        resourceClass === "com.example.ztrans" ||
        windowRole === "ztrans-popup";
}

function clamp(value, minValue, maxValue) {
    if (value < minValue) {
        return minValue;
    }
    if (value > maxValue) {
        return maxValue;
    }
    return value;
}

function getPlacementArea(window, cursor) {
    const output = typeof workspace.screenAt === "function" ? workspace.screenAt(cursor) : null;
    if (output) {
        return workspace.clientArea(KWin.PlacementArea, output, workspace.currentDesktop);
    }
    return workspace.clientArea(KWin.PlacementArea, window);
}

function getTargetGeometry(window) {
    if (!matchesZTrans(window)) {
        return null;
    }

    const geometry = window.frameGeometry;
    const width = Math.round(geometry.width);
    const height = Math.round(geometry.height);

    if (width <= 1 || height <= 1) {
        return null;
    }

    const cursor = workspace.cursorPos;
    const area = getPlacementArea(window, cursor);

    const minX = Math.round(area.x);
    const minY = Math.round(area.y);
    const maxX = Math.max(minX, Math.round(area.x + area.width - width));
    const maxY = Math.max(minY, Math.round(area.y + area.height - height));

    const preferredX = Math.round(cursor.x - (width / 2));
    const x = clamp(preferredX, minX, maxX);

    const belowY = Math.round(cursor.y + GAP);
    const aboveY = Math.round(cursor.y - GAP - height);
    const y = belowY <= maxY ? clamp(belowY, minY, maxY) : clamp(aboveY, minY, maxY);

    return {
        x: x,
        y: y,
        width: width,
        height: height
    };
}

function geometryMatches(window, target) {
    const geometry = window.frameGeometry;
    return Math.round(geometry.x) === target.x &&
        Math.round(geometry.y) === target.y &&
        Math.round(geometry.width) === target.width &&
        Math.round(geometry.height) === target.height;
}

function placeWindow(window, state) {
    const target = getTargetGeometry(window);
    if (!target) {
        return false;
    }

    if (geometryMatches(window, target)) {
        state.placed = true;
        return true;
    }

    if (state.adjusting) {
        return false;
    }

    state.adjusting = true;
    window.frameGeometry = Qt.rect(target.x, target.y, target.width, target.height);
    return true;
}

function ensureTracked(window) {
    if (trackedWindows.has(window)) {
        return trackedWindows.get(window);
    }

    const state = { adjusting: false, placed: false };
    trackedWindows.set(window, state);
    window.frameGeometryChanged.connect(() => {
        if (!matchesZTrans(window)) {
            return;
        }

        if (state.adjusting) {
            state.adjusting = false;
        }

        placeWindow(window, state);
    });
    window.closed.connect(() => {
        trackedWindows.delete(window);
    });
    return state;
}

function handleWindow(window) {
    if (!matchesZTrans(window)) {
        return;
    }

    const state = ensureTracked(window);
    if (state.placed) {
        return;
    }

    if (placeWindow(window, state)) {
        state.placed = true;
    }
}

function handleShownWindow(window) {
    if (!matchesZTrans(window)) {
        return;
    }

    const state = ensureTracked(window);
    state.placed = false;
    handleWindow(window);
}

function main() {
    workspace.windowList().forEach(handleWindow);
    workspace.windowAdded.connect(handleWindow);
    if (typeof workspace.windowShown !== "undefined") {
        workspace.windowShown.connect(handleShownWindow);
    }
}

main();
