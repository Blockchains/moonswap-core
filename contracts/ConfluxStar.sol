pragma solidity =0.5.16;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/introspection/IERC1820Registry.sol";
import "@openzeppelin/contracts/token/ERC777/IERC777Recipient.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/ownership/Ownable.sol";
import "@openzeppelin/contracts/token/ERC777/IERC777.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "./Pauseable.sol";
import './SponsorWhitelistControl.sol';

/**
 * Interstellar migration
 * Welcome to Conflux Star ##Farm
 *
 */
contract ConfluxStar is Ownable, Pauseable, IERC777Recipient {
  using SafeMath for uint256;
  using SafeERC20 for IERC20;

  SponsorWhitelistControl constant public SPONSOR = SponsorWhitelistControl(address(0x0888000000000000000000000000000000000001));
  IERC1820Registry private _erc1820 = IERC1820Registry(0x866aCA87FF33a0ae05D2164B3D999A804F583222);
  // keccak256("ERC777TokensRecipient")
  bytes32 constant private TOKENS_RECIPIENT_INTERFACE_HASH =
    0xb281fc8c12954d22544db45de3159a39272895b169a852b314f9cc762e44c53b;

  struct UserInfo {
    uint256 amount;
    uint256 rewardDebt;
  }

  struct PoolInfo {
    IERC20 lpToken;           // Address of LP token contract.
    uint256 allocPoint;       // How many allocation points assigned to this pool. Moons to distribute per block.
    uint256 lastRewardTime;  //
    uint256 accTokenPerShare; //
  }

  // Moon crosschain atom mapping
  address public cMoonToken;
  uint256 public tokenPerSecond;
  uint256 public startFarmTime;

  // Info of each pool.
  PoolInfo[] public poolInfo;
  // Info of each user that stakes LP tokens.
  mapping (uint256 => mapping (address => UserInfo)) public userInfo;
  // Total allocation poitns. Must be the sum of all allocation points in all pools.
  uint256 public totalAllocPoint = 0;
  // The block number when Token mining starts.
  uint256 public startBlock;
  mapping(address => uint256) public poolIndexs;

  event TokenTransfer(address indexed tokenAddress, address indexed from, address to, uint value);
  event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
  event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
  event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);

  constructor(
        address _cMoon,
        uint256 _tokenPerSecond,
        uint256 _startTime
    ) public {
        cMoonToken = _cMoon;
        tokenPerSecond = _tokenPerSecond; // Calculate the production rate according to the mining situation
        startFarmTime = _startTime;


        _erc1820.setInterfaceImplementer(address(this), TOKENS_RECIPIENT_INTERFACE_HASH, address(this));

        // register all users as sponsees
        address[] memory users = new address[](1);
        users[0] = address(0);
        SPONSOR.add_privilege(users);
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    function add(uint256 _allocPoint, IERC20 _lpToken, bool _withUpdate) public onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        require(poolIndexs[address(_lpToken)] < 1, "LpToken exists");
        uint256 lastRewardTime = block.timestamp > startFarmTime ? block.timestamp : startFarmTime;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolInfo.push(PoolInfo({
            lpToken: _lpToken,
            allocPoint: _allocPoint,
            lastRewardTime: lastRewardTime,
            accTokenPerShare: 0
        }));

        poolIndexs[address(_lpToken)] = poolInfo.length;
    }

    function set(uint256 _pid, uint256 _allocPoint, bool _withUpdate) public onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(_allocPoint);
        poolInfo[_pid].allocPoint = _allocPoint;
    }

    function setTokenPerSecond(uint256 _tokenPerSecond) public onlyOwner {
        massUpdatePools();

        tokenPerSecond = _tokenPerSecond;
    }

    function pendingToken(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accTokenPerShare = pool.accTokenPerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (block.timestamp > pool.lastRewardTime && lpSupply != 0) {
            uint256 tokenReward = _getPoolReward(pool.lastRewardTime);
            accTokenPerShare = accTokenPerShare.add(tokenReward.mul(1e12).div(lpSupply));
        }

        return user.amount.mul(accTokenPerShare).div(1e12).sub(user.rewardDebt);
    }

    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.timestamp <= pool.lastRewardTime) {
            return;
        }
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (lpSupply == 0) {
            pool.lastRewardTime = block.timestamp;
            return;
        }

        uint256 tokenReward = _getPoolReward(pool.lastRewardTime);

        pool.accTokenPerShare = pool.accTokenPerShare.add(tokenReward.mul(1e12).div(lpSupply));
        pool.lastRewardTime = block.timestamp;
    }

    //
    function deposit(uint256 _pid, uint256 _amount, address to) public {
        if(to == address(0)){
            to = address(msg.sender);
        }

        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][to];
        updatePool(_pid);
        if (user.amount > 0) {
            uint256 pending = user.amount.mul(pool.accTokenPerShare).div(1e12).sub(user.rewardDebt);
            safeTokenTransfer(to, pending);
        }
        pool.lpToken.safeTransferFrom(to, address(this), _amount);
        user.amount = user.amount.add(_amount);
        user.rewardDebt = user.amount.mul(pool.accTokenPerShare).div(1e12);
        emit Deposit(to, _pid, _amount);
    }

    function withdraw(uint256 _pid, uint256 _amount) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(_amount > 0, "user amount is zero");
        require(user.amount >= _amount, "withdraw: not good");
        updatePool(_pid);
        uint256 pending = user.amount.mul(pool.accTokenPerShare).div(1e12).sub(user.rewardDebt);
        safeTokenTransfer(msg.sender, pending);
        user.amount = user.amount.sub(_amount);
        user.rewardDebt = user.amount.mul(pool.accTokenPerShare).div(1e12);
        pool.lpToken.safeTransfer(address(msg.sender), _amount);
        emit Withdraw(msg.sender, _pid, _amount);
    }

    function emergencyWithdraw(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 _amount = user.amount;
        require(_amount > 0, "user amount is zero");
        user.amount = 0;
        user.rewardDebt = 0;

        pool.lpToken.safeTransfer(address(msg.sender), _amount);
        emit EmergencyWithdraw(msg.sender, _pid, _amount);
    }

    function moonBalance() external view returns(uint256) {
      return IERC20(cMoonToken).balanceOf(address(this));
    }

    function safeTokenTransfer(address _to, uint256 _amount) internal {
        uint256 tokenBal = IERC20(cMoonToken).balanceOf(address(this));
        require(_amount <= tokenBal, "ConfluxStar: Balance insufficient");
        IERC20(cMoonToken).transfer(_to, _amount);
    }

    function _getPoolReward(uint256 _poolLastRewardTime) internal view returns(uint256) {
        uint256 _timestamp = block.timestamp;
        return _timestamp.sub(_poolLastRewardTime).mul(tokenPerSecond);
    }

    // custodian deposit
    function tokensReceived(address operator, address from, address to, uint amount,
          bytes calldata userData,
          bytes calldata operatorData) external {

          emit TokenTransfer(msg.sender, from, to, amount);
    }
}