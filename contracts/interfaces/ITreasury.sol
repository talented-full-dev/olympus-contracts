// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.7.5;


interface ITreasury {

    function deposit( address _from, uint _amount, address _token, uint _profit ) external returns ( uint );

    function valueOf( address _token, uint _amount ) external view returns ( uint value_ );
    
    function mintRewards( address _recipient, uint _amount ) external;
}