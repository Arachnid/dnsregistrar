pragma solidity ^0.4.23;

import "./ens.sol";
import "./dnssec-oracle/contracts/Buffer.sol";
import "./dnssec-oracle/contracts/DNSSEC.sol";
import "./dnssec-oracle/contracts/BytesUtils.sol";
import "./dnssec-oracle/contracts/RRUtils.sol";

/**
 * @dev An ENS registrar that allows the owner of a DNS name to claim the
 *      corresponding name in ENS.
 */
contract DNSRegistrar {
    using BytesUtils for bytes;
    using RRUtils for *;
    using Buffer for Buffer.buffer;

    event Log(string message, bytes value);
    event Log(string message, bytes32 value);
    event Log(string message, address value);

    uint16 constant CLASS_INET = 1;
    uint16 constant TYPE_TXT = 16;

    DNSSEC public oracle;
    ENS public ens;
    bytes public rootDomain;
    bytes32 public rootNode;

    function DNSRegistrar(DNSSEC _dnssec, ENS _ens, bytes _rootDomain, bytes32 _rootNode) public {
        oracle = _dnssec;
        ens = _ens;
        rootDomain = _rootDomain;
        rootNode = _rootNode;
    }

    function claim(bytes name) public {
        bytes32 labelHash = getLabelHash(name);

        address addr = getOwnerAddress(name);
        // Anyone can set the address to 0, but only the owner can claim a name.
        require(addr == 0 || addr == msg.sender);

        ens.setSubnodeOwner(rootNode, labelHash, addr);
    }

    function getLabelHash(bytes memory name) internal view returns(bytes32) {
        uint len = name.readUint8(0);
        // Check this name is a direct subdomain of the one we're responsible for
        require(name.equals(len + 1, rootDomain));
        return name.keccak(1, len);
    }

    function getOwnerAddress(bytes memory name) internal view returns(address) {
        // Add "_ens." to the front of the name.
        Buffer.buffer memory buf;
        buf.init(name.length + 5);
        buf.append("\x04_ens");
        buf.append(name);

        // Query the oracle for TXT records
        var (, inserted, rrs) = oracle.rrset(CLASS_INET, TYPE_TXT, buf.buf);

        for(RRUtils.RRIterator memory iter = rrs.iterateRRs(0); !iter.done(); iter.next()) {
            require(inserted + iter.ttl >= now, "DNS record is stale; refresh or delete it before proceeding.");

            address addr = parseRR(rrs, iter.rdataOffset);
            if(addr != 0) {
                return addr;
            }
        }

        return 0;
    }

    function parseRR(bytes memory rdata, uint idx) internal pure returns(address) {
        while(idx < rdata.length) {
            uint len = rdata.readUint8(idx); idx += 1;
            address addr = parseString(rdata, idx, len);
            if(addr != 0) return addr;
            idx += len;
        }

        return 0;
    }

    function parseString(bytes memory str, uint idx, uint len) internal pure returns(address) {
        // TODO: More robust parsing that handles whitespace and multiple key/value pairs
        if(str.readUint32(idx) != 0x613d3078) return 0; // 0x613d3078 == 'a=0x'
        if(len < 44) return 0;
        return hexToAddress(str, idx + 4);
    }

    function hexToAddress(bytes memory str, uint idx) internal pure returns(address) {
        if(str.length - idx < 40) return 0;
        uint ret = 0;
        for(uint i = idx; i < idx + 40; i++) {
            ret <<= 4;
            uint x = str.readUint8(i);
            if(x >= 48 && x < 58) {
                ret |= x - 48;
            } else if(x >= 65 && x < 71) {
                ret |= x - 55;
            } else if(x >= 97 && x < 103) {
                ret |= x - 87;
            } else {
                return 0;
            }
        }
        return address(ret);
    }
}
