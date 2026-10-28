import express from "express";
import dotenv from "dotenv";
import fs from "fs";
import path from "path";
import mongoose from "mongoose";

import { connectDB } from "./config/db.js";

import productRoutes from "./routes/product.route.js";

dotenv.config();

const app = express();
const PORT = process.env.PORT || 5000;

const __dirname = path.resolve();

app.use(express.json()); // allows us to accept JSON data in the req.body

app.get("/api/health", (req, res) => {
	const databaseConnected = mongoose.connection.readyState === 1;

	res.status(databaseConnected ? 200 : 503).json({
		status: databaseConnected ? "ok" : "degraded",
		database: databaseConnected ? "connected" : "disconnected",
		uptime: process.uptime(),
	});
});

app.use("/api/products", productRoutes);

const frontendIndex = path.join(__dirname, "frontend", "dist", "index.html");

if (process.env.NODE_ENV === "production" && fs.existsSync(frontendIndex)) {
	app.use(express.static(path.dirname(frontendIndex)));
	app.get("*", (req, res) => {
		res.sendFile(frontendIndex);
	});
}

app.listen(PORT, () => {
	connectDB();
	console.log("Server started at http://localhost:" + PORT);
});
