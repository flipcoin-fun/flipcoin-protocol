export const FactoryV2Abi = [
  {
    "type": "constructor",
    "inputs": [
      {
        "name": "_admin",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "_protocolAddress",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "_marketImplementation",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "_vault",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "_shareToken",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "_exchange",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "_backstopRouter",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "_delegationRegistry",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "_defaultTotalFeeBps",
        "type": "uint16",
        "internalType": "uint16"
      },
      {
        "name": "_defaultCreatorFeeBps",
        "type": "uint16",
        "internalType": "uint16"
      },
      {
        "name": "_defaultProtocolFeeBps",
        "type": "uint16",
        "internalType": "uint16"
      },
      {
        "name": "_minMarketDuration",
        "type": "uint64",
        "internalType": "uint64"
      },
      {
        "name": "_maxMarketDuration",
        "type": "uint64",
        "internalType": "uint64"
      }
    ],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "CREATE_MARKET_TYPEHASH",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "bytes32",
        "internalType": "bytes32"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "DELEGATED_CREATE_TYPEHASH",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "bytes32",
        "internalType": "bytes32"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "addRelayer",
    "inputs": [
      {
        "name": "relayer",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "backstopRouter",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "contract BackstopRouter"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "config",
    "inputs": [],
    "outputs": [
      {
        "name": "admin",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "protocolAddress",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "defaultTotalFeeBps",
        "type": "uint16",
        "internalType": "uint16"
      },
      {
        "name": "defaultCreatorFeeBps",
        "type": "uint16",
        "internalType": "uint16"
      },
      {
        "name": "defaultProtocolFeeBps",
        "type": "uint16",
        "internalType": "uint16"
      },
      {
        "name": "minMarketDuration",
        "type": "uint64",
        "internalType": "uint64"
      },
      {
        "name": "maxMarketDuration",
        "type": "uint64",
        "internalType": "uint64"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "createMarket",
    "inputs": [
      {
        "name": "params",
        "type": "tuple",
        "internalType": "struct MarketParams",
        "components": [
          {
            "name": "question",
            "type": "string",
            "internalType": "string"
          },
          {
            "name": "description",
            "type": "string",
            "internalType": "string"
          },
          {
            "name": "category",
            "type": "string",
            "internalType": "string"
          },
          {
            "name": "resolutionRules",
            "type": "string",
            "internalType": "string"
          },
          {
            "name": "resolutionSource",
            "type": "string",
            "internalType": "string"
          },
          {
            "name": "imageUrl",
            "type": "string",
            "internalType": "string"
          },
          {
            "name": "deadline",
            "type": "uint64",
            "internalType": "uint64"
          }
        ]
      },
      {
        "name": "seedUsdc",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "initialPriceYesBps",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "market",
        "type": "address",
        "internalType": "address"
      }
    ],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "createMarketFor",
    "inputs": [
      {
        "name": "params",
        "type": "tuple",
        "internalType": "struct MarketParams",
        "components": [
          {
            "name": "question",
            "type": "string",
            "internalType": "string"
          },
          {
            "name": "description",
            "type": "string",
            "internalType": "string"
          },
          {
            "name": "category",
            "type": "string",
            "internalType": "string"
          },
          {
            "name": "resolutionRules",
            "type": "string",
            "internalType": "string"
          },
          {
            "name": "resolutionSource",
            "type": "string",
            "internalType": "string"
          },
          {
            "name": "imageUrl",
            "type": "string",
            "internalType": "string"
          },
          {
            "name": "deadline",
            "type": "uint64",
            "internalType": "uint64"
          }
        ]
      },
      {
        "name": "seedUsdc",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "initialPriceYesBps",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "creator",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "deadline",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "requestId",
        "type": "bytes32",
        "internalType": "bytes32"
      },
      {
        "name": "v",
        "type": "uint8",
        "internalType": "uint8"
      },
      {
        "name": "r",
        "type": "bytes32",
        "internalType": "bytes32"
      },
      {
        "name": "s",
        "type": "bytes32",
        "internalType": "bytes32"
      }
    ],
    "outputs": [
      {
        "name": "market",
        "type": "address",
        "internalType": "address"
      }
    ],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "createMarketForDelegated",
    "inputs": [
      {
        "name": "params",
        "type": "tuple",
        "internalType": "struct MarketParams",
        "components": [
          {
            "name": "question",
            "type": "string",
            "internalType": "string"
          },
          {
            "name": "description",
            "type": "string",
            "internalType": "string"
          },
          {
            "name": "category",
            "type": "string",
            "internalType": "string"
          },
          {
            "name": "resolutionRules",
            "type": "string",
            "internalType": "string"
          },
          {
            "name": "resolutionSource",
            "type": "string",
            "internalType": "string"
          },
          {
            "name": "imageUrl",
            "type": "string",
            "internalType": "string"
          },
          {
            "name": "deadline",
            "type": "uint64",
            "internalType": "uint64"
          }
        ]
      },
      {
        "name": "seedUsdc",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "initialPriceYesBps",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "owner",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "signer",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "deadline",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "requestId",
        "type": "bytes32",
        "internalType": "bytes32"
      },
      {
        "name": "v",
        "type": "uint8",
        "internalType": "uint8"
      },
      {
        "name": "r",
        "type": "bytes32",
        "internalType": "bytes32"
      },
      {
        "name": "s",
        "type": "bytes32",
        "internalType": "bytes32"
      }
    ],
    "outputs": [
      {
        "name": "market",
        "type": "address",
        "internalType": "address"
      }
    ],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "creationPaused",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "bool",
        "internalType": "bool"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "delegationRegistry",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "contract DelegationRegistry"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "eip712Domain",
    "inputs": [],
    "outputs": [
      {
        "name": "fields",
        "type": "bytes1",
        "internalType": "bytes1"
      },
      {
        "name": "name",
        "type": "string",
        "internalType": "string"
      },
      {
        "name": "version",
        "type": "string",
        "internalType": "string"
      },
      {
        "name": "chainId",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "verifyingContract",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "salt",
        "type": "bytes32",
        "internalType": "bytes32"
      },
      {
        "name": "extensions",
        "type": "uint256[]",
        "internalType": "uint256[]"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "exchange",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "contract Exchange"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "getMarketByCondition",
    "inputs": [
      {
        "name": "conditionId",
        "type": "bytes32",
        "internalType": "bytes32"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "getMarketById",
    "inputs": [
      {
        "name": "id",
        "type": "uint64",
        "internalType": "uint64"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "getMarketInfo",
    "inputs": [
      {
        "name": "id",
        "type": "uint64",
        "internalType": "uint64"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "tuple",
        "internalType": "struct MarketInfo",
        "components": [
          {
            "name": "marketId",
            "type": "uint64",
            "internalType": "uint64"
          },
          {
            "name": "market",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "creator",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "conditionId",
            "type": "bytes32",
            "internalType": "bytes32"
          },
          {
            "name": "deadline",
            "type": "uint64",
            "internalType": "uint64"
          },
          {
            "name": "createdAt",
            "type": "uint64",
            "internalType": "uint64"
          }
        ]
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "marketByConditionId",
    "inputs": [
      {
        "name": "",
        "type": "bytes32",
        "internalType": "bytes32"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "marketIdByAddress",
    "inputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "uint64",
        "internalType": "uint64"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "marketImplementation",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "markets",
    "inputs": [
      {
        "name": "",
        "type": "uint64",
        "internalType": "uint64"
      }
    ],
    "outputs": [
      {
        "name": "marketId",
        "type": "uint64",
        "internalType": "uint64"
      },
      {
        "name": "market",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "creator",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "conditionId",
        "type": "bytes32",
        "internalType": "bytes32"
      },
      {
        "name": "deadline",
        "type": "uint64",
        "internalType": "uint64"
      },
      {
        "name": "createdAt",
        "type": "uint64",
        "internalType": "uint64"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "nextMarketId",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint64",
        "internalType": "uint64"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "nonces",
    "inputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "pauseCreation",
    "inputs": [],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "removeRelayer",
    "inputs": [
      {
        "name": "relayer",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "shareToken",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "contract ShareToken"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "transferAdmin",
    "inputs": [
      {
        "name": "newAdmin",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "trustedRelayers",
    "inputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "bool",
        "internalType": "bool"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "unpauseCreation",
    "inputs": [],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "usedRequestIds",
    "inputs": [
      {
        "name": "",
        "type": "bytes32",
        "internalType": "bytes32"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "bool",
        "internalType": "bool"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "vault",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "contract VaultV2"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "event",
    "name": "AdminTransferred",
    "inputs": [
      {
        "name": "oldAdmin",
        "type": "address",
        "indexed": false,
        "internalType": "address"
      },
      {
        "name": "newAdmin",
        "type": "address",
        "indexed": false,
        "internalType": "address"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "CreationPaused",
    "inputs": [
      {
        "name": "admin",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "CreationUnpaused",
    "inputs": [
      {
        "name": "admin",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "EIP712DomainChanged",
    "inputs": [],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "MarketCreatedViaRelayer",
    "inputs": [
      {
        "name": "marketId",
        "type": "uint64",
        "indexed": true,
        "internalType": "uint64"
      },
      {
        "name": "market",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "creator",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "relayer",
        "type": "address",
        "indexed": false,
        "internalType": "address"
      },
      {
        "name": "requestId",
        "type": "bytes32",
        "indexed": false,
        "internalType": "bytes32"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "MarketV2Created",
    "inputs": [
      {
        "name": "marketId",
        "type": "uint64",
        "indexed": true,
        "internalType": "uint64"
      },
      {
        "name": "market",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "creator",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "conditionId",
        "type": "bytes32",
        "indexed": false,
        "internalType": "bytes32"
      },
      {
        "name": "b",
        "type": "int256",
        "indexed": false,
        "internalType": "int256"
      },
      {
        "name": "seedUsdc",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      },
      {
        "name": "initialPriceYesBps",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      },
      {
        "name": "deadline",
        "type": "uint64",
        "indexed": false,
        "internalType": "uint64"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "RelayerAdded",
    "inputs": [
      {
        "name": "relayer",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "RelayerRemoved",
    "inputs": [
      {
        "name": "relayer",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      }
    ],
    "anonymous": false
  },
  {
    "type": "error",
    "name": "CreationIsPaused",
    "inputs": []
  },
  {
    "type": "error",
    "name": "DurationTooLong",
    "inputs": []
  },
  {
    "type": "error",
    "name": "DurationTooShort",
    "inputs": []
  },
  {
    "type": "error",
    "name": "ECDSAInvalidSignature",
    "inputs": []
  },
  {
    "type": "error",
    "name": "ECDSAInvalidSignatureLength",
    "inputs": [
      {
        "name": "length",
        "type": "uint256",
        "internalType": "uint256"
      }
    ]
  },
  {
    "type": "error",
    "name": "ECDSAInvalidSignatureS",
    "inputs": [
      {
        "name": "s",
        "type": "bytes32",
        "internalType": "bytes32"
      }
    ]
  },
  {
    "type": "error",
    "name": "FailedDeployment",
    "inputs": []
  },
  {
    "type": "error",
    "name": "InsufficientBalance",
    "inputs": [
      {
        "name": "balance",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "needed",
        "type": "uint256",
        "internalType": "uint256"
      }
    ]
  },
  {
    "type": "error",
    "name": "InvalidShortString",
    "inputs": []
  },
  {
    "type": "error",
    "name": "InvalidSignature",
    "inputs": []
  },
  {
    "type": "error",
    "name": "NotAdmin",
    "inputs": []
  },
  {
    "type": "error",
    "name": "NotDelegated",
    "inputs": []
  },
  {
    "type": "error",
    "name": "NotRelayer",
    "inputs": []
  },
  {
    "type": "error",
    "name": "PriceOutOfRange",
    "inputs": []
  },
  {
    "type": "error",
    "name": "QuestionRequired",
    "inputs": []
  },
  {
    "type": "error",
    "name": "RequestAlreadyUsed",
    "inputs": []
  },
  {
    "type": "error",
    "name": "SeedTooHigh",
    "inputs": []
  },
  {
    "type": "error",
    "name": "SeedTooLow",
    "inputs": []
  },
  {
    "type": "error",
    "name": "SignatureExpired",
    "inputs": []
  },
  {
    "type": "error",
    "name": "StringTooLong",
    "inputs": [
      {
        "name": "str",
        "type": "string",
        "internalType": "string"
      }
    ]
  }
] as const;
