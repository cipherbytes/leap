#include <eosio/chain_plugin/chain_plugin.hpp>
#include <trx_provider.hpp>

#include <boost/algorithm/string.hpp>

#include <fc/bitutil.hpp>
#include <fc/io/json.hpp>

#include <contracts.hpp>

#include <iostream>

enum return_codes {
   OTHER_FAIL = -2,
   INITIALIZE_FAIL = -1,
   SUCCESS = 0,
   BAD_ALLOC = 1,
   DATABASE_DIRTY = 2,
   FIXED_REVERSIBLE = SUCCESS,
   EXTRACTED_GENESIS = SUCCESS,
   NODE_MANAGEMENT_SUCCESS = 5
};

uint64_t _total_us = 0;
uint64_t _txcount = 0;

using namespace eosio::testing;
using namespace eosio::chain;
using namespace eosio;

vector<pair<eosio::chain::action, eosio::chain::action>> create_initial_transfer_actions(const std::string& salt, const uint64_t& period, const name& newaccountT, const vector<name>& accounts, const fc::microseconds& abi_serializer_max_time) {
   vector<pair<eosio::chain::action, eosio::chain::action>> actions_pairs_vector;

   abi_serializer eosio_token_serializer{fc::json::from_string(contracts::eosio_token_abi().data()).as<abi_def>(), abi_serializer::create_yield_function(abi_serializer_max_time)};

   for(size_t i = 0; i < accounts.size(); ++i) {
      for(size_t j = i + 1; j < accounts.size(); ++j) {
         //create the actions here
         ilog("create_initial_transfer_actions: creating transfer from ${acctA} to ${acctB}", ("acctA", accounts.at(i))("acctB", accounts.at(j)));
         action act_a_to_b;
         act_a_to_b.account = newaccountT;
         act_a_to_b.name = "transfer"_n;
         act_a_to_b.authorization = vector<permission_level>{{accounts.at(i), config::active_name}};
         act_a_to_b.data = eosio_token_serializer.variant_to_binary("transfer",
                                                                    fc::json::from_string(fc::format_string("{\"from\":\"${from}\",\"to\":\"${to}\",\"quantity\":\"1.0000 CUR\",\"memo\":\"${l}\"}",
                                                                    fc::mutable_variant_object()("from", accounts.at(i).to_string())("to", accounts.at(j).to_string())("l", salt))),
                                                                    abi_serializer::create_yield_function(abi_serializer_max_time));

         ilog("create_initial_transfer_actions: creating transfer from ${acctB} to ${acctA}", ("acctB", accounts.at(j))("acctA", accounts.at(i)));
         action act_b_to_a;
         act_b_to_a.account = newaccountT;
         act_b_to_a.name = "transfer"_n;
         act_b_to_a.authorization = vector<permission_level>{{accounts.at(j), config::active_name}};
         act_b_to_a.data = eosio_token_serializer.variant_to_binary("transfer",
                                                                    fc::json::from_string(fc::format_string("{\"from\":\"${from}\",\"to\":\"${to}\",\"quantity\":\"1.0000 CUR\",\"memo\":\"${l}\"}",
                                                                    fc::mutable_variant_object()("from", accounts.at(j).to_string())("to", accounts.at(i).to_string())("l", salt))),
                                                                    abi_serializer::create_yield_function(abi_serializer_max_time));

         actions_pairs_vector.push_back(make_pair(act_a_to_b, act_b_to_a));
      }
   }
   ilog("create_initial_transfer_actions: total action pairs created: ${pairs}", ("pairs", actions_pairs_vector.size()));
   return actions_pairs_vector;
}

vector<signed_transaction> create_intial_transfer_transactions(uint64_t nonce_prefix, const vector<pair<eosio::chain::action, eosio::chain::action>>& action_pairs_vector, const fc::microseconds& trx_expiration, const chain_id_type& chain_id, const block_id_type& reference_block_id) {
   std::vector<signed_transaction> trxs;
   trxs.reserve(2 * action_pairs_vector.size());

   using action_pair = pair<eosio::chain::action, eosio::chain::action>;

   try {
      static fc::crypto::private_key a_priv_key = fc::crypto::private_key::regenerate(fc::sha256(std::string(64, 'a')));
      static fc::crypto::private_key b_priv_key = fc::crypto::private_key::regenerate(fc::sha256(std::string(64, 'b')));

      static uint64_t nonce = static_cast<uint64_t>(fc::time_point::now().sec_since_epoch()) << 32;

      for(action_pair acts : action_pairs_vector) {
         {
            signed_transaction trx;
            trx.actions.push_back(acts.first);
            trx.context_free_actions.emplace_back(action({}, config::null_account_name, name("nonce"), fc::raw::pack(std::to_string(nonce_prefix) +":"+ std::to_string(++nonce)+":"+fc::time_point::now().time_since_epoch().count())));
            trx.set_reference_block(reference_block_id);
            trx.expiration = fc::time_point::now() + trx_expiration;
            trx.max_net_usage_words = 100;
            trx.sign(a_priv_key, chain_id);
            trxs.emplace_back(std::move(trx));
         }

         {
            signed_transaction trx;
            trx.actions.push_back(acts.second);
            trx.context_free_actions.emplace_back(action({}, config::null_account_name, name("nonce"), fc::raw::pack(std::to_string(nonce_prefix) +":"+ std::to_string(++nonce)+":"+fc::time_point::now().time_since_epoch().count())));
            trx.set_reference_block(reference_block_id);
            trx.expiration = fc::time_point::now() + trx_expiration;
            trx.max_net_usage_words = 100;
            trx.sign(b_priv_key, chain_id);
            trxs.emplace_back(std::move(trx));
         }
      }
   } catch(const std::bad_alloc&) {
      throw;
   } catch(const boost::interprocess::bad_alloc&) {
      throw;
   } catch(const fc::exception&) {
      throw;
   } catch(const std::exception&) {
      throw;
   }

   return trxs;
}

void stop_generation() {
   ilog("Stopping transaction generation");

   if(_txcount) {
      ilog("${d} transactions executed, ${t}us / transaction", ("d", _txcount)("t", _total_us / (double) _txcount));
      _txcount = _total_us = 0;
   }
}

chain::block_id_type make_block_id(uint32_t block_num) {
   chain::block_id_type block_id;
   block_id._hash[0] &= 0xffffffff00000000;
   block_id._hash[0] += fc::endian_reverse_u32(block_num);
   return block_id;
}

vector<name> get_accounts(const vector<string>& account_str_vector) {
   vector<name> acct_name_list;
   for(string account_name: account_str_vector) {
      ilog("get_account about to try to create name for ${acct}", ("acct", account_name));
      acct_name_list.push_back(eosio::chain::name(account_name));
   }
   return acct_name_list;
}

int main(int argc, char** argv) {
   const uint32_t TRX_EXPIRATION_MAX = 3600;
   variables_map vmap;
   options_description cli("Transaction Generator command line options.");
   string chain_id_in;
   string hAcct;
   string accts;
   uint32_t abi_serializer_max_time_us;
   uint32_t trx_expr;
   uint32_t reference_block_num;

   vector<string> account_str_vector;


   cli.add_options()
      ("chain-id", bpo::value<string>(&chain_id_in), "set the chain id")
      ("handler-account", bpo::value<string>(&hAcct), "Account name of the handler account for the transfer actions")
      ("accounts", bpo::value<string>(&accts), "comma-separated list of accounts that will be used for transfers. Minimum required accounts: 2.")
      ("abi-serializer-max-time-us", bpo::value<uint32_t>(&abi_serializer_max_time_us)->default_value(15 * 1000), "maximum abi serializer time in microseconds (us). Defaults to 15,000.")
      ("trx-expiration", bpo::value<uint32_t>(&trx_expr)->default_value(3600), "transaction expiration time in microseconds (us). Defaults to 3,600. Maximum allowed: 3,600")
      ("ref-block-num", bpo::value<uint32_t>(&reference_block_num)->default_value(0), "the reference block (last_irreversible_block_num or head_block_num) to use for transactions. Defaults to 0.")
      ("help,h", "print this list")
      ;

   try {
      bpo::store(bpo::parse_command_line(argc, argv, cli), vmap);
      bpo::notify(vmap);

      if(vmap.count("help") > 0) {
         cli.print(std::cerr);
         return SUCCESS;
      }

      if(!vmap.count("chain-id")) {
         ilog("Initialization error: missing chain-id");
         cli.print(std::cerr);
         return INITIALIZE_FAIL;
      }

      if(vmap.count("handler-account")) {
      } else {
         ilog("Initialization error: missing handler-account");
         cli.print(std::cerr);
         return INITIALIZE_FAIL;
      }

      if(vmap.count("accounts")) {
         boost::split(account_str_vector, accts, boost::is_any_of(","));
         if(account_str_vector.size() < 2) {
            ilog("Initialization error: requires at minimum 2 transfer accounts");
            cli.print(std::cerr);
            return INITIALIZE_FAIL;
         }
      } else {
         ilog("Initialization error: did not specify transfer accounts. requires at minimum 2 transfer accounts");
         cli.print(std::cerr);
         return INITIALIZE_FAIL;
      }

      if(vmap.count("trx-expiration")) {
         if(trx_expr > TRX_EXPIRATION_MAX) {
            ilog("Initialization error: Exceeded max value for transaction expiration. Value must be less than ${max}.", ("max", TRX_EXPIRATION_MAX));
            cli.print(std::cerr);
            return INITIALIZE_FAIL;
         }
      }
   } catch(bpo::unknown_option& ex) {
      std::cerr << ex.what() << std::endl;
      cli.print(std::cerr);
      return INITIALIZE_FAIL;
   }

   try {
      ilog("Initial chain id ${chainId}", ("chainId", chain_id_in));
      ilog("Handler account ${acct}", ("acct", hAcct));
      ilog("Transfer accounts ${accts}", ("accts", accts));
      ilog("Abi serializer max time microsections ${asmt}", ("asmt", abi_serializer_max_time_us));
      ilog("Transaction expiration microsections ${expr}", ("expr", trx_expr));
      ilog("Reference block number ${blkNum}", ("blkNum", reference_block_num));

      //Example chain ids:
      // cf057bbfb72640471fd910bcb67639c22df9f92470936cddc1ade0e2f2e7dc4f
      // 60fb0eb4742886af8a0e147f4af6fd363e8e8d8f18bdf73a10ee0134fec1c551
      const chain_id_type chain_id(chain_id_in);
      const name handlerAcct = eosio::chain::name(hAcct);
      const vector<name> accounts = get_accounts(account_str_vector);
      fc::microseconds trx_expiration{trx_expr};
      const static fc::microseconds abi_serializer_max_time = fc::microseconds(abi_serializer_max_time_us);

      const std::string salt = "";
      const uint64_t& period = 20;
      uint64_t nonce_prefix = 0;

      //TODO: Revisit if this type of update is necessary
      // uint32_t reference_block_num = cc.last_irreversible_block_num();
      // // if (txn_reference_block_lag >= 0) {
      // //    reference_block_num = cc.head_block_num();
      // //    if (reference_block_num <= (uint32_t)txn_reference_block_lag) {
      // //       reference_block_num = 0;
      // //    } else {
      // //       reference_block_num -= (uint32_t)txn_reference_block_lag;
      // //    }
      // // }
      // block_id_type reference_block_id = cc.get_block_id_for_num(reference_block_num);
      block_id_type reference_block_id = make_block_id(reference_block_num);

      std::cout << "Create All Initial Transfer Action/Reaction Pairs (acct 1 -> acct 2, acct 2 -> acct 1) between all provided accounts." << std::endl;
      const auto action_pairs_vector = create_initial_transfer_actions(salt, period, handlerAcct, accounts, abi_serializer_max_time);

      std::cout << "Stop Generation." << std::endl;
      stop_generation();

      std::cout << "Create All Initial Transfer Transactions (one for each created action)." << std::endl;
      std::vector<signed_transaction> trxs = create_intial_transfer_transactions(nonce_prefix++, action_pairs_vector, trx_expiration, chain_id, reference_block_id);

      std::cout << "Setup p2p transaction provider" << std::endl;
      p2p_trx_provider provider = p2p_trx_provider();
      provider.setup();

      std::cout << "send all initial transactions via p2p transaction provider" << std::endl;
      std::vector<signed_transaction> single_send = std::vector<signed_transaction>();
      single_send.reserve(1);
      for(signed_transaction trx : trxs)
      {
         single_send.emplace_back(trx);
         provider.send(single_send);
         single_send.clear();
         ++_txcount;
      }

      std::cout << "Sent transactions: " << _txcount << std::endl;

      std::cout << "Tear down p2p transaction provider" << std::endl;
      provider.teardown();

      //Stop & Cleanup
      std::cout << "Stop Generation." << std::endl;
      stop_generation();

   } catch(const std::exception& e) {
      elog("${e}", ("e", e.what()));
      return OTHER_FAIL;
   } catch(...) {
      elog("unknown exception");
      return OTHER_FAIL;
   }

   return SUCCESS;
}
