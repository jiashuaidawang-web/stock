package com.dunwugudao.replay.mapper.ck;

import com.dunwugudao.replay.entity.LeaderPoolDaily;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;

import java.time.LocalDate;
import java.util.List;

/**
 * 每日龙头池产出（ClickHouse: leader_pool_daily）。按交易日幂等重算：先删后写。
 */
@Mapper
public interface LeaderPoolDailyMapper {

    int deleteByTradeDate(@Param("tradeDate") LocalDate tradeDate);

    int insertBatch(@Param("list") List<LeaderPoolDaily> list);
}
