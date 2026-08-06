"use strict";

const repositoryUrl = "https://github.com/echo1097/routerchat";
const redirectDelay = 800;

window.addEventListener("load", () => {
  window.setTimeout(() => {
    window.location.replace(repositoryUrl);
  }, redirectDelay);
});
