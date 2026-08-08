package com.dunwugudao.replay.mapper.ck;

import com.dunwugudao.replay.entity.MainlineDaily;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;

import java.time.LocalDate;
import java.util.List;

/**
 * 每日主线板块产出（ClickHouse: mainline_daily）。按交易日幂等重算：先删后写。
 */
@Mapper
public interface MainlineDailyMapper {

    int deleteByTradeDate(@Param("tradeDate") LocalDate tradeDate);

    int insertBatch(@Param("list") List<MainlineDaily> list);
}
