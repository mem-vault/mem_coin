#[test_only]
#[allow(duplicate_alias)]
module mem_coin::memvault_tests {
    use sui::coin;
    use sui::coin::zero;
    use sui::sui::SUI;
    use sui::transfer;          // 显式导入以便调用 public_transfer
    use std::string;
    use mem_coin::memvault;
    use mem_coin::memvault::ServiceWitness;
    use sui::tx_context;

    // ------------------------------------------------------------
    // 1. 创建服务测试
    // ------------------------------------------------------------
    #[test]
    fun test_create_service() {
        let mut ctx = tx_context::dummy();
        let name = string::utf8(b"TestService");
        let description = string::utf8(b"Test Description");
        let url = string::utf8(b"https://test.com");
        let total_supply = 10_000;
        let min_holding = 100;
        let initial_sui_liquidity = zero<SUI>(&mut ctx);

        let (service, cap, owner_coin) = memvault::create_service_for_test(
            name,
            description,
            url,
            total_supply,
            initial_sui_liquidity,
            min_holding,
            &mut ctx,
        );

        // 检查 owner_coin 数量（20% 流通）
        assert!(
            coin::value(&owner_coin) == total_supply - total_supply * 80 / 100,
            101
        );

        memvault::destroy_service_for_test(service, cap);
        transfer::public_transfer(owner_coin, @0x1);
    }

    #[test]
    fun test_publish() {
        let mut ctx = tx_context::dummy();
        let name = string::utf8(b"TestService");
        let description = string::utf8(b"Test Description");
        let url = string::utf8(b"https://test.com");
        let total_supply = 10_000;
        let min_holding = 100;
        let initial_sui_liquidity = zero<SUI>(&mut ctx);

        let (mut service, cap, owner_coin) = memvault::create_service_for_test(
            name,
            description,
            url,
            total_supply,
            initial_sui_liquidity,
            min_holding,
            &mut ctx,
        );

        memvault::publish(&mut service, &cap, string::utf8(b"test-blob"), &mut ctx);

        memvault::destroy_service_for_test(service, cap);
        transfer::public_transfer(owner_coin, @0x1);
    }

    #[test]
    fun test_swap_and_withdraw() {
        let mut ctx = tx_context::dummy();
        let name = string::utf8(b"SwapService");
        let description = string::utf8(b"Test Description");
        let url = string::utf8(b"https://test.com");
        let total_supply = 10_000;
        let min_holding = 100;
        let initial_sui_liquidity = coin::mint_for_testing<SUI>(1_000, &mut ctx);

        let (mut service, cap, owner_coin) = memvault::create_service_for_test(
            name,
            description,
            url,
            total_supply,
            initial_sui_liquidity,
            min_holding,
            &mut ctx,
        );

        // Test SUI → MEM swap
        let sui_in = coin::mint_for_testing<SUI>(500, &mut ctx);
        let mem_out = memvault::swap_sui_for_memecoin(&mut service, sui_in, 1, &mut ctx);
        assert!(coin::value(&mem_out) > 0, 103);

        // Test MEM → SUI swap
        let sui_out = memvault::swap_memecoin_for_sui(&mut service, mem_out, 1, &mut ctx);
        assert!(coin::value(&sui_out) > 0, 104);

        // Test admin withdrawals
        let admin_sui_coin = memvault::admin_withdraw_sui(&mut service, 50, &mut ctx);
        assert!(coin::value(&admin_sui_coin) == 50, 105);
        transfer::public_transfer(admin_sui_coin, @0x1);

        let admin_mem_coin = memvault::admin_withdraw_memecoin(&mut service, 50, &mut ctx);
        assert!(coin::value(&admin_mem_coin) == 50, 106);
        transfer::public_transfer(admin_mem_coin, @0x1);

        transfer::public_transfer(sui_out, @0x1);
        transfer::public_transfer(owner_coin, @0x1);

        memvault::destroy_service_for_test(service, cap);
    }
}