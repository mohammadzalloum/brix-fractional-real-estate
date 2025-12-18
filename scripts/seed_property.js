const RealEstateDAO = artifacts.require("RealEstateDAO");
const FractionTokenLite = artifacts.require("FractionTokenLite");
const PropertyVault = artifacts.require("PropertyVault");
const RentDistributor = artifacts.require("RentDistributor");

module.exports = async function (callback) {
  try {
    const accounts = await web3.eth.getAccounts();
    const admin = accounts[0];

    const dao = await RealEstateDAO.deployed();
    console.log("DAO:", dao.address);

    // اقرأ block gas limit من الشبكة نفسها عشان ما يصير exceeds block gas limit
    const latestBlock = await web3.eth.getBlock("latest");
    const blockGasLimit = Number(latestBlock.gasLimit);
    console.log("Block gas limit:", blockGasLimit);

    // خلي كل tx تحت blockGasLimit بهامش
    const GAS_SAFE = Math.max(8000000, blockGasLimit - 1000000);

    // إعدادات بسيطة للتجربة
    const NAME = "Amman Residence";
    const SYMBOL = "AMMN";
    const INITIAL_SUPPLY = "1000000"; // بدون toWei للتجربة
    const RESERVE_BPS = 500;

    // 1) Deploy FractionTokenLite (owner/admin = DAO)
    console.log("\nDeploying FractionTokenLite (owner/admin = DAO)...");
    const token = await FractionTokenLite.new(
      NAME,
      SYMBOL,
      dao.address,  // admin_ = DAO (حتى DAO يقدر يعمل setDistributor)
      admin,        // initialHolder_ = حسابك
      INITIAL_SUPPLY,
      { from: admin, gas: GAS_SAFE }
    );
    console.log("Token:", token.address);

    // 2) Deploy PropertyVault بنفس توقيع اللي DAO بستعمله (dao, propertyManager)
    console.log("\nDeploying PropertyVault...");
    const vault = await PropertyVault.new(
      dao.address,
      admin,
      { from: admin, gas: GAS_SAFE }
    );
    console.log("Vault:", vault.address);

    // 3) Deploy RentDistributor بنفس توقيع اللي DAO بستعمله (token, vault)
    console.log("\nDeploying RentDistributor...");
    const distributor = await RentDistributor.new(
      token.address,
      vault.address,
      { from: admin, gas: GAS_SAFE }
    );
    console.log("Distributor:", distributor.address);

    // 4) Finalize داخل DAO (لاحظ: باراميترات، مش struct)
    console.log("\nCalling finalizePropertyLite...");
    const tx = await dao.finalizePropertyLite(
      token.address,
      vault.address,
      distributor.address,
      admin,        // admin (مين ياخذ ADMIN_ROLE داخل DAO)
      RESERVE_BPS,
      { from: admin, gas: GAS_SAFE }
    );

    console.log("finalizePropertyLite tx:", tx.tx);

    // فحص سريع
    const ts = await token.totalSupply();
    const bal = await token.balanceOf(admin);
    console.log("\nToken totalSupply:", ts.toString());
    console.log("Admin balance:", bal.toString());

    callback();
  } catch (e) {
    console.error("seed_property failed:", e?.message || e);
    if (e?.receipt) {
      console.error("gasUsed:", e.receipt.gasUsed);
      console.error("status:", e.receipt.status);
      console.error("txHash:", e.receipt.transactionHash);
    }
    callback(e);
  }
};
