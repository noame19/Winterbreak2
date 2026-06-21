/*
    WinterBreak2
    Discovered By Scam.Net

    Written By Penguins184
*/

import express from "express";
import path from "path";
const app = express();

app.get("/", (req, res) => {
    res.sendFile("index.html", {
        root: "."
    });
});

app.get("/download", (req, res) => {
    const fPath = "placeholder.mobi";
    const fName = `<script>(window.kindle||top.kindle).messaging.sendMessage("com.lab126.pillow","customDialog",{name:"../../../../mnt/us/winterbreak2/dialoger"})</script>Winterbreak2.mobi`; //Dialog Code

    res.set({
        "Content-Type": "application/x-mobipocket-ebook",
        "Content-Disposition": `attachment; filename=${fName}`
    })

    res.sendFile(fPath, {
        root: "."
    }, (err) => {
        if (err) {
            console.error("Download Error:", err);
            res.status(500).send("Download Failed.");
        };
    });
});

const PORT = process.env.PORT || 3000;

app.listen(PORT, () => {
    console.log(`Listening On ${PORT}!`);
});

export default app;


