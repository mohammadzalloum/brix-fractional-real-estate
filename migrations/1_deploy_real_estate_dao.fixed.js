const fs = require("fs");
const path = require("path");

const RealEstateDAO = artifacts.require("RealEstateDAO");

module.exports = async function (deployer, network) {
  await deployer.deploy(RealEstateDAO);
  const dao = await RealEstateDAO.deployed();

  console.log("RealEstateDAO deployed at:", dao.address);

  // Optional: keep your frontend in sync for local dev
  const outDir = path.join(__dirname, "..", "frontend", "src", "config", "deployments");
  fs.mkdirSync(outDir, { recursive: true });
  const outPath = path.join(outDir, "local.json");
  fs.writeFileSync(outPath, JSON.stringify({ network, RealEstateDAO: dao.address }, null, 2));
  console.log("Wrote frontend deployment file:", outPath);
};
