'use strict';

exports.mongodb = "mongodb://localhost/autobids";
exports.mongoose_debug = true;

//multer incoming upload directory
exports.multer = {
    dest: "/mnt/datalad/easybids/upload",
}
//directory to copy uploaded files (it needs to be on the same filesystem as multer incoming dir)
exports.workdir = "/mnt/datalad/easybids/workdir",

exports.express = {
    port: 12507,
}
