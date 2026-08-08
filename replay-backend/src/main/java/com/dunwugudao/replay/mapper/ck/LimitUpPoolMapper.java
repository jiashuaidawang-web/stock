package com.dunwugudao.replay.mapper.ck;

import com.dunwugudao.replay.entity.ck.raw.LimitUpPool;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;

import java.time.LocalDate;
import java.util.List;

@Mapper
public interface LimitUpPoolMapper {

    List<LimitUpPool> selectByTradeDate(@Param("tradeDate") LocalDate tradeDate);

    /** 已入库的最大交易日；为空表示尚未爬取。 */
    LocalDate selectMaxTradeDate();
}
