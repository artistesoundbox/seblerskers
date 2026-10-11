// Rewrite the warrior GLBs from the .orig backups, then decimate.
"use strict";
const fs = require("fs");
const { execSync } = require("child_process");

// True originals: git blob e1e012... (viking, stored raw) and LFS object
// f65dd5... (warrior north). grep -r those out fresh each time, so the
// decimator always starts from 1.62M triangles.
const vikingGitBlob = execSync(
  "git cat-file blob e1e012bcffae5d4d830fb8b5e68d58041e893ed4",
  { maxBuffer: 1024 * 1024 * 1024 });
require("fs").writeFileSync("viking_warrior.glb", vikingGitBlob);
require("fs").copyFileSync(
  ".git/lfs/objects/f6/5d/f65dd5601fa61729c1b0d26d05b719a14cf0be03af7dd573f5c4a77776d4ef2b",
  "warrior_of_the_north.glb");
console.log("restored originals:",
  require("fs").statSync("viking_warrior.glb").size,
  require("fs").statSync("warrior_of_the_north.glb").size);
execSync("node Tools/decimate2.js",
  { stdio: "inherit", cwd: "C:/Users/Anthonitus/Documents/GitHub/vitahuesosite/seblerskers" });
