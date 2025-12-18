module.exports = {
  networks: {
    development: {
      host: "127.0.0.1",
      port: 8545,
      network_id: "1337",
      gas: 900000000,
      gasPrice: 2000000000,
    },
  },
  compilers: {
    solc: {
      version: "./node_modules/solc/soljson.js",
      settings: {
        optimizer: { enabled: true, runs: 200 },
      },
    },
  },
};
